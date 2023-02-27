// main template for appuio-cloud-reporting
local alerts = import 'alerts.libsonnet';
local common = import 'common.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local netPol = import 'networkpolicies.libsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.appuio_cloud_reporting;

local formatImage = function(ref) '%(registry)s/%(repository)s:%(tag)s' % ref;

local escape = function(str)
  std.join('',
           std.map(
             function(c)
               if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) then c else '-'
             , str
           ));

local dbSecret = kube.Secret('reporting-db') {
  assert params.database.password != null : 'database.password must be set.',
  metadata+: {
    namespace: params.namespace,
    labels+: common.Labels,
  },
  stringData: {
    username: params.database.username,
    password: params.database.password,
  },
};

local promURLSecret = kube.Secret('prom-url') {
  assert params.prometheus.url != null : 'prometheus.url must be set.',
  metadata+: {
    namespace: params.namespace,
    labels+: common.Labels,
  },
  stringData: {
    url: params.prometheus.url,
  },
};

local erpURLSecret = kube.Secret('erp-url') {
  assert params.database.password != null : 'erp_adapter.url must be set.',
  metadata+: {
    namespace: params.namespace,
    labels+: common.Labels,
  },
  stringData: {
    url: params.erp_adapter.url,
  },
};

local dbEnv = [
  {
    name: 'password',
    valueFrom: {
      secretKeyRef: {
        key: 'password',
        name: dbSecret.metadata.name,
      },
    },
  },
  {
    name: 'username',
    valueFrom: {
      secretKeyRef: {
        key: 'username',
        name: dbSecret.metadata.name,
      },
    },
  },
  {
    assert params.database.host != null : 'database.host must be set.',
    name: 'ACR_DB_URL',
    value: 'postgres://$(username):$(password)@%(host)s:%(port)s/%(name)s?%(parameters)s' % params.database,
  },
  {
    name: 'OA_DB_URL',
    value: '$(ACR_DB_URL)',
  },
];

local promEnv = std.prune([
  {
    name: 'ACR_PROM_URL',
    valueFrom: {
      secretKeyRef: {
        key: 'url',
        name: promURLSecret.metadata.name,
      },
    },
  },
  if params.prometheus.org_id != null then {
    name: 'ACR_ORG_ID',
    value: params.prometheus.org_id,
  },
]);

local erpEnv = [
  {
    name: 'OA_ODOO_URL',
    valueFrom: {
      secretKeyRef: {
        key: 'url',
        name: erpURLSecret.metadata.name,
      },
    },
  },
  {
    name: 'OA_INVOICE_TITLE',
    value: params.erp_adapter.invoice_title,
  },
];

local checkMigrationContainer = {
  name: 'check-migration',
  image: formatImage(params.images.reporting),
  env+: dbEnv,
  args: [
    'migrate',
    '--show-pending',
  ],
};

local checkMissingContainer = {
  name: 'check-missing',
  image: formatImage(params.images.reporting),
  env+: dbEnv,
  args: [ 'check_missing' ],
  resources: {},
};

local syncCategoriesContainer = {
  name: 'sync-categories',
  image: formatImage(params.images.erp_adapter),
  env+: dbEnv + erpEnv,
  args: [
    'sync',
  ],
};

local tenantMappingCJ = common.CronJob('tenant-mapping', 'tenantmapping', {
  initContainers: [
    checkMigrationContainer,
  ],
  containers: [
    {
      name: 'mapping',
      image: formatImage(params.images.reporting),
      env+: dbEnv + promEnv,
      command: [ 'sh', '-c' ],
      args: [
        'appuio-cloud-reporting tenantmapping --begin=$(date -d "now -3 hours" -u +"%Y-%m-%dT%H:00:00Z") --repeat-until=$(date -u -Iseconds)'
        + (' --dry-run=%s' % std.toString(params.tenantmapping.dry_run))
        + (" --additional-metric-selector='%s'" % std.toString(params.tenantmapping.metrics_selector)),
      ],
      resources: {},
    },
  ],
}) {
  spec+: {
    // Keeping infinite jobs is not possible. Keep at least one month worth of jobs.
    failedJobsHistoryLimit: 24 * 32,
  },
};

local backfillCJ = function(queryName)
  common.CronJob('backfill-%s' % escape(queryName), 'backfill', {
    initContainers: [
      checkMigrationContainer,
    ],
    containers: [
      {
        name: 'backfill',
        image: formatImage(params.images.reporting),
        env+: dbEnv + promEnv,
        command: [ 'sh', '-c' ],
        args: [
          'appuio-cloud-reporting report --begin=$(date -d "now -3 hours" -u +"%Y-%m-%dT%H:00:00Z") --repeat-until=$(date -u -Iseconds) --query-name=' + queryName,
        ],
        resources: {},
      },
    ],
  }) {
    metadata+: {
      annotations+: {
        'query-name': queryName,
      },
    },
    spec+: {
      jobTemplate+: {
        metadata+: {
          annotations+: {
            'query-name': queryName,
          },
        },
      },
      // Keeping infinite jobs is not possible. Keep at least one month worth of jobs.
      failedJobsHistoryLimit: 24 * 32,
    },
  };

local checkCJ = common.CronJob('check-missing', 'check_missing', {
  initContainers: [
    checkMigrationContainer,
    syncCategoriesContainer,
  ],
  containers: [
    checkMissingContainer,
  ],
});

local invoiceCJ = common.CronJob('generate-invoices', 'invoice', {
  restartPolicy: 'Never',
  initContainers: [
    checkMigrationContainer,
    syncCategoriesContainer,
    checkMissingContainer,
  ],
  containers: [
    {
      name: 'invoice',
      image: formatImage(params.images.erp_adapter),
      env+: dbEnv + erpEnv,
      command: [ 'sh', '-c' ],
      args: [ 'appuio-odoo-adapter invoice --year=$(date -d "now -1 months" -u +"%Y") --month=$(date -d "now -1 months" -u +"%-m")' ],
      resources: {},
    },
  ],
}) {
  spec+: {
    jobTemplate+: {
      spec+: {
        backoffLimit: 0,
      },
    },
  },
};


// Define outputs below
{
  '00_namespace': kube.Namespace(params.namespace) {
    metadata+: {
      labels+: common.Labels {
        'openshift.io/cluster-monitoring': 'true',
      },
    },
  },
  '01_netpol': netPol.Policies,
  '10_db_secret': dbSecret,
  '10_prom_secret': promURLSecret,
  '10_erp_secret': erpURLSecret,
  '11_tenant_mapping': tenantMappingCJ,
  '11_backfill': std.filterMap(
    function(k) params.backfill.queries[k] == true,
    function(k) backfillCJ(k),
    std.objectFields(params.backfill.queries)
  ),
  '12_check_missing': checkCJ,
  '20_invoice': invoiceCJ,
  [if params.monitoring.enabled then '50_alerts']: alerts.Alerts,
}
