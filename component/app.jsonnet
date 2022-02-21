local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.appuio_cloud_reporting;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('appuio-cloud-reporting', params.namespace);

{
  'appuio-cloud-reporting': app,
}
