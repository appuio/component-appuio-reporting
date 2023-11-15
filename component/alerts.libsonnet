local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.appuio_reporting;

local alertlabels = {
  syn: 'true',
  syn_component: 'appuio-reporting',
};

local alertParams = params.monitoring.alerts;

local alerts =
  kube._Object('monitoring.coreos.com/v1', 'PrometheusRule', 'appuio-reporting') {
    metadata+: {
      namespace: params.namespace,
      labels+: common.Labels,
    },
    spec+: {
      groups+: [
        {
          name: 'appuio-reporting.alerts',
          rules:
            std.filterMap(
              function(field) alertParams[field].enabled == true,
              function(field) alertParams[field].rule {
                alert: field,
                labels+: alertlabels,
              },
              std.sort(std.objectFields(alertParams))
            ),
        },
      ],
    },
  };

{
  Alerts: alerts,
}
