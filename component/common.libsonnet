local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.appuio_reporting;

local labels = {
  'app.kubernetes.io/name': 'appuio-reporting',
  'app.kubernetes.io/managed-by': 'commodore',
  'app.kubernetes.io/part-of': 'syn',
};

local cronJob = function(name, scheduleName, jobSpec)
  local schedule = params.schedules[scheduleName];
  local suspend =
    local s = params.schedules_suspend[scheduleName];
    if s && !params.development_mode then
      error (
        '\n\nSuspending cronjobs not possible unless the component is in development mode.\n'
        + 'Please note that suspending the cronjobs will partially or completely disable APPUiO Cloud billing.\n'
        + 'To enable development mode, set parameter `development_mode` to true.\n'
      )
    else
      s;
  kube._Object('batch/v1', 'CronJob', name) {
    metadata+: {
      namespace: params.namespace,
      labels+: labels,
    },
    spec: {
      // set startingDeadlineSeconds to ensure that new jobs will be scheduled
      // if the cronjob is unsuspended after a long period of being suspended.
      // This is required because any jobs that would have been scheduled
      // while the CronJob is suspended count as missed and without
      // startingDeadlineSeconds set, the CronJob controller will not schedule
      // new jobs if >100 jobs were missed. See the following upstream
      // documentation:
      // * https://kubernetes.io/docs/tasks/job/automated-tasks-with-cron-jobs/#suspend
      // * https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/#cron-job-limitations
      startingDeadlineSeconds: 180,
      schedule: schedule,
      successfulJobsHistoryLimit: 3,
      failedJobsHistoryLimit: 3,
      jobTemplate: {
        metadata: {
          labels+: labels {
            'cron-job-name': name,
          },
        },
        spec: {
          template: {
            metadata: {
              labels+: labels,
            },
            spec: {
              restartPolicy: 'OnFailure',
              initContainers: [],
              containers: [],
            } + jobSpec,
          },
        },
      },
      suspend: suspend,
    },
  };


{
  Labels: labels,
  CronJob: cronJob,
}
