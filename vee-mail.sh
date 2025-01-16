#!/bin/bash

VERSION=0.5.49
HDIR=$(dirname "$0")
DEBUG=0
INFOMAIL=1
SENDM=0
SLEEP=60

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" 
  logger -t vee-mail "This script must be run as root"
  exit 1
fi

# Source your config
. $HDIR/$1

# Make sure the script picks up the multiple job names
IFS=',' read -ra JOBS <<< "$JOBNAME"

STARTEDFROM=$(ps -p $PPID -hco cmd)
if [ "$1" == "--bg" ]; then
  if [ "$STARTEDFROM" == "veeamjobman" ]; then
    logger -t vee-mail "waiting for ${SLEEP} seconds"
    sleep $SLEEP
  fi
fi

VC=$(which veeamconfig)
if [ -z "$VC" ]; then
  echo "No Veeam Agent for Linux installed!"
  logger -t vee-mail "No Veeam Agent for Linux installed!"
  exit
fi

# (Install dependencies logic remains the same)
...

# Loop over each job name
for oneJobName in "${JOBS[@]}"; do
    
    # Trim whitespace, just in case
    oneJobName="$(echo "$oneJobName" | xargs)"

    # Adjust the session ID fetch. We want the MOST RECENT session for the current job name
    # so we limit the job_name in the query:
    VV=$(veeamconfig -v|cut -c2)

    if [ $VV -ge 6 ]; then
      # get the most recent session ID for the specific job
      # The 'job_name' in the DB is typically EXACT to what Veeam sees, so watch out for spacing.
      SESSID=$($VC session list --name "$oneJobName" | grep -v "Total amount" | tail -1 | awk '{print $(NF-7)}')
    else
      SESSID=$($VC session list --name "$oneJobName" | grep -v "Total amount" | tail -1 | awk '{print $(NF-5)}')
    fi
    SESSID=${SESSID:1:${#SESSID}-2}

    if [ $VV -ge 6 ]; then
      SESSDATA=$(sqlite3 /var/lib/veeam/veeam_db.sqlite \
        "SELECT start_time_utc, end_time_utc, state, progress_details, job_id, job_name 
         FROM JobSessions 
         WHERE job_name='$oneJobName'
         ORDER BY start_time_utc DESC
         LIMIT 1;"
      )
    else
      SESSDATA=$(sqlite3 /var/lib/veeam/veeam_db.sqlite \
        "SELECT start_time, end_time, state, progress_details, job_id, job_name 
         FROM JobSessions 
         WHERE job_name='$oneJobName'
         ORDER BY start_time DESC
         LIMIT 1;"
      )
    fi

    STARTTIME=$(echo $SESSDATA | awk -F'|' '{print $1}')
    ENDTIME=$(echo $SESSDATA   | awk -F'|' '{print $2}')
    STATE=$(echo $SESSDATA    | awk -F'|' '{print $3}')
    DETAILS=$(echo $SESSDATA  | awk -F'|' '{print $4}')
    JOBID=$(echo $SESSDATA    | awk -F'|' '{print $5}')
    JOBNAME=$(echo $SESSDATA  | awk -F'|' '{print $6}')

    # If there's no session data, skip
    if [ -z "$SESSDATA" ] || [ -z "$JOBID" ]; then
      logger -t vee-mail "No sessions found for job [$oneJobName], skipping..."
      continue
    fi

    # The rest of your logic for building the email content,
    # collecting stats, building HTML, etc. remains the same.
    # e.g. parse $DETAILS for PROCESSED, READ, TRANSFERRED, etc.
    # parse $JOBID for repository info, etc.
    # Then build the email / send it.

    # ...
    # ...
    # create the subject, etc.
    HN=${HOSTNAME^^}
    SUBJECT=$(echo "[$STAT] $HN - $START ($JOBNAME)" | base64 -w0)
    ...
    # Then send

done  # end for oneJobName in JOBS

exit 0

