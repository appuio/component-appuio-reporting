// main template for appuio-reporting
local alerts = import 'alerts.libsonnet';
local common = import 'common.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local netPol = import 'networkpolicies.libsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.appuio_reporting;

local formatImage = function(ref) '%(registry)s/%(repository)s:%(tag)s' % ref;

local escape = function(str)
  std.join('',
           std.map(
             function(c)
               if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) then c else '-'
             , str
           ));

local odooSecret = kube.Secret('odoo-credentials') {
  metadata+: {
    namespace: params.namespace,
    labels+: common.Labels,
  },
  stringData: {
    [name]: params.odoo.oauth[name]
    for name in std.objectFields(params.odoo.oauth)
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

local commonEnv = std.prune([
  {
    name: 'ACR_ODOO_OAUTH_TOKEN_URL',
    valueFrom: {
      secretKeyRef: {
        name: odooSecret.metadata.name,
        key: 'token_url',
      },
    },
  },
  {
    name: 'ACR_ODOO_OAUTH_CLIENT_ID',
    valueFrom: {
      secretKeyRef: {
        name: odooSecret.metadata.name,
        key: 'client_id',
      },
    },
  },
  {
    name: 'ACR_ODOO_OAUTH_CLIENT_SECRET',
    valueFrom: {
      secretKeyRef: {
        name: odooSecret.metadata.name,
        key: 'client_secret',
      },
    },
  },
  {
    name: 'ACR_ODOO_URL',
    value: params.odoo.metered_billing_endpoint,
  },
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

local override_sales_order_id = if params.override_sales_order_id != null && !params.development_mode then
  error (
    '\n\nOverriding sales order ID not possible unless the component is in development mode.\n'
    + 'Please note that overriding the sales order ID may produce faulty invoices.\n'
    + 'To enable development mode, set parameter `development_mode` to true.\n'
  )
else
  params.override_sales_order_id;

local backfillCJ = function(rule, product)
  local query = rule.query_pattern % product.params;

  local itemDescJsonnet = if std.objectHas(rule, 'item_description_jsonnet') then
    rule.item_description_jsonnet
  else if std.objectHas(rule, 'item_description_pattern') then
    'local labels = std.extVar("labels"); "%s" %% labels' % rule.item_description_pattern;

  local itemGroupDescJsonnet = if std.objectHas(rule, 'item_group_description_jsonnet') then
    rule.item_group_description_jsonnet
  else if std.objectHas(rule, 'item_group_description_pattern') then
    'local labels = std.extVar("labels"); "%s" %% labels' % rule.item_group_description_pattern;

  local instanceJsonnet = if std.objectHas(rule, 'instance_id_jsonnet') then
    rule.instance_id_jsonnet
  else
    'local labels = std.extVar("labels"); "%s" %% labels' % rule.instance_id_pattern;

  local jobEnv = std.prune([
    {
      name: 'AR_PRODUCT_ID',
      value: product.product_id,
    },
    {
      name: 'AR_QUERY',
      value: query,
    },
    {
      name: 'AR_INSTANCE_JSONNET',
      value: instanceJsonnet,
    },
    if itemGroupDescJsonnet != null then {
      name: 'AR_ITEM_GROUP_DESCRIPTION_JSONNET',
      value: itemGroupDescJsonnet,
    },
    if itemDescJsonnet != null then {
      name: 'AR_ITEM_DESCRIPTION_JSONNET',
      value: itemDescJsonnet,
    },
    {
      name: 'AR_UNIT_ID',
      value: rule.unit_id,
    },
  ]);
  common.CronJob('backfill-%s' % escape(product.product_id), 'backfill', {
    containers: [
      {
        name: 'backfill',
        image: formatImage(params.images.reporting),
        env+: commonEnv + jobEnv,
        command: [ 'sh', '-c' ],
        args: [
          'appuio-reporting report --begin=$(date -d "now -3 hours" -u +"%Y-%m-%dT%H:00:00Z") --repeat-until=$(date -u -Iseconds)' + (if override_sales_order_id != null then ' --debug-override-sales-order-id=' + override_sales_order_id else ''),
        ],
        resources: {},
        [if std.length(params.extra_volumes) > 0 then 'volumeMounts']: [
          { name: name } + params.extra_volumes[name].mount_spec
          for name in std.objectFields(params.extra_volumes)
        ],
      },
    ],
    [if std.length(params.extra_volumes) > 0 then 'volumes']: [
      { name: name } + params.extra_volumes[name].volume_spec
      for name in std.objectFields(params.extra_volumes)
    ],
  }) {
    metadata+: {
      annotations+: {
        'product-id': product.product_id,
      },
    },
    spec+: {
      jobTemplate+: {
        metadata+: {
          annotations+: {
            'product-id': product.product_id,
          },
        },
      },
      // Keeping infinite jobs is not possible. Keep at least one month worth of jobs.
      failedJobsHistoryLimit: 24 * 32,
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
  '10_prom_secret': promURLSecret,
  '10_odoo_secret': odooSecret,
  '11_backfill': std.flatMap(function(r) [ backfillCJ(r, p) for p in r.products ], std.filter(function(r) r.enabled, std.objectValues(params.rules))),
  [if params.monitoring.enabled then '50_alerts']: alerts.Alerts,
}
