#!/bin/bash

# vee-mail.sh
# A script that sends email notifications for one or more Veeam jobs.
# Now uses the "id" column from the JobSessions table instead of session_id.

VERSION=0.6.0
HDIR=$(dirname "$0")

##################################################
# Default or initial values
##################################################
DEBUG=0         # can be overridden by config
INFOMAIL=1      # can be overridden by config
SENDM=0
SLEEP=60

# Must run as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" 
  logger -t vee-mail "This script must be run as root"
  exit 1
fi

# Source config (the .config file, e.g. vee-mail.config)
if [ ! "$1" ]; then
 . "$HDIR/vee-mail.config"
else
 . "$HDIR/$1"
fi

# If config sets SLEEP, use that; else default stays 60
if [ -z "$SLEEP" ]; then
  SLEEP=60
fi

STARTEDFROM=$(ps -p $PPID -hco cmd)
if [ "$1" == "--bg" ]; then
  if [ "$STARTEDFROM" == "veeamjobman" ]; then
    logger -t vee-mail "waiting for ${SLEEP} seconds"
    sleep "$SLEEP"
  fi
fi

# Where is veeamconfig?
VC=$(which veeamconfig)
if [ -z "$VC" ]; then
  echo "No Veeam Agent for Linux installed!"
  logger -t vee-mail "No Veeam Agent for Linux installed!"
  exit 1
fi

# Veeam version number (2nd char, e.g. "6" from "v6.0.0.0")
VV=$($VC -v 2>/dev/null | cut -c2)

# Possibly set by config or system
YUM=$(which yum 2>/dev/null)
SQLITE=$(which sqlite3 2>/dev/null)
CURL=$(which curl 2>/dev/null)
SENDMAIL=$(which sendmail 2>/dev/null)

##################################################
# Install dependencies if missing
##################################################
if [ "$SQLITE" != "/usr/bin/sqlite3" ] && [ "$SQLITE" != "/bin/sqlite3" ]; then
  if [ "$YUM" ]; then
    yum install -y sqlite3
  else
    apt-get install -y sqlite3
  fi
fi

if [ $USECURL -eq 1 ] && [ -z "$CURL" ]; then
  if [ "$YUM" ]; then
    yum install -y curl
  else
    apt-get install -y curl
  fi
fi

if [ $USECURL -ne 1 ] && [ "$SENDMAIL" != "/usr/sbin/sendmail" ] && [ "$SENDMAIL" != "/bin/sendmail" ]; then
  if [ "$YUM" ]; then
    yum install -y sendmail
  else
    apt-get install -y sendmail
  fi
fi

##################################################
# Optional version check if SKIPVERSIONCHECK=0
##################################################
if [ $SKIPVERSIONCHECK -ne 1 ]; then
  if [ "$CURL" ]; then
    AKTVERSION=$($CURL -m2 -f -s https://raw.githubusercontent.com/grufocom/vee-mail/master/vee-mail.sh --stderr - | grep "^VERSION=" | awk -F'=' '{print $2}')
    if [ "$AKTVERSION" ]; then
      HIGHESTVERSION=$(echo -e "$VERSION\n$AKTVERSION" | sort -rV | head -n1)
      if [ "$VERSION" != "$HIGHESTVERSION" ]; then
        logger -t vee-mail "new Vee-Mail version $AKTVERSION available"
        AKTVERSION="(new Vee-Mail version $AKTVERSION available)"
      else
        AKTVERSION=""
      fi
    fi
  else
    AKTVERSION="(you need curl to use the upgrade check, please install)"
  fi
else
  VERSION="$VERSION (upgrade check disabled)"
fi

AGENT=$($VC -v)

##################################################
# Grab multiple job names from config
##################################################
IFS=',' read -ra JOBS <<< "$JOBNAME"

##################################################
# Function: Build and send mail for the given job
##################################################
function send_job_mail() {
  local oneJobName="$1"

  ######################################
  # Step 1: Grab the latest session from DB for the job
  # Since your DB has "id" instead of "session_id",
  # we select "id, start_time_utc, end_time_utc, ..."
  ######################################
  local SESSDATA
  if [ "$VV" -ge 6 ]; then
    # For v6+ we might use start_time_utc
    SESSDATA=$(sqlite3 /var/lib/veeam/veeam_db.sqlite \
      "SELECT id, start_time_utc, end_time_utc, state, progress_details, job_id, job_name
       FROM JobSessions
       WHERE job_name='$oneJobName'
       ORDER BY start_time_utc DESC
       LIMIT 1;")
  else
    # For older v3-v5, might use start_time
    SESSDATA=$(sqlite3 /var/lib/veeam/veeam_db.sqlite \
      "SELECT id, start_time, end_time, state, progress_details, job_id, job_name
       FROM JobSessions
       WHERE job_name='$oneJobName'
       ORDER BY start_time DESC
       LIMIT 1;")
  fi

  # If there's no session data, bail for this job
  if [ -z "$SESSDATA" ]; then
    logger -t vee-mail "No session for job [$oneJobName], skipping..."
    return
  fi

  # Parse the columns we selected
  local SESSID STARTTIME ENDTIME STATE DETAILS JOBID THISJOBNAME
  SESSID=$(    echo "$SESSDATA" | awk -F'|' '{print $1}')
  STARTTIME=$( echo "$SESSDATA" | awk -F'|' '{print $2}')
  ENDTIME=$(   echo "$SESSDATA" | awk -F'|' '{print $3}')
  STATE=$(     echo "$SESSDATA" | awk -F'|' '{print $4}')
  DETAILS=$(   echo "$SESSDATA" | awk -F'|' '{print $5}')
  JOBID=$(     echo "$SESSDATA" | awk -F'|' '{print $6}')
  THISJOBNAME=$(echo "$SESSDATA"| awk -F'|' '{print $7}')

  # Basic sanity check
  if [ -z "$SESSID" ] || [ -z "$JOBID" ]; then
    logger -t vee-mail "No valid session ID or job ID for [$oneJobName]"
    return
  fi

  ######################################
  # Step 2: Get session log (error/warn)
  ######################################
  local ERRLOG
  ERRLOG=$($VC session log --id "$SESSID" 2>/dev/null \
           | egrep 'error|warn' \
           | sed ':a;N;$!ba;s/\n/<br>/g' \
           | sed -e "s/ /\\&nbsp;/g")
  ERRLOG=$(printf "%q" "$ERRLOG")
  if [ "$ERRLOG" == "''" ]; then
    ERRLOG=""
  fi

  ######################################
  # Step 3: Parse the DB for backup repo info
  ######################################
  local RAWTARGET TARGET FST LOGIN DOMAIN LOCALDEV
  RAWTARGET=$(sqlite3 /var/lib/veeam/veeam_db.sqlite \
    "SELECT a1.options
     FROM BackupRepositories AS a1
     LEFT JOIN BackupJobs AS a2 ON a1.id = a2.repository_id
     WHERE a2.id='$JOBID';")

  TARGET=$(echo "$RAWTARGET" \
    | awk -F'Address="' '{print $2}' \
    | awk -F'"' '{print $1}' \
    | sed -e "s/^\\///g")

  FST=$(echo "$RAWTARGET" \
    | awk -F'FsType="' '{print $2}' \
    | awk -F'"' '{print $1}')

  LOGIN=$(echo "$RAWTARGET" \
    | awk -F'Login="' '{print $2}' \
    | awk -F'"' '{print $1}')

  DOMAIN=$(echo "$RAWTARGET" \
    | awk -F'Domain="' '{print $2}' \
    | awk -F'"' '{print $1}')

  # If no "TARGET", maybe local deviceMountPoint
  if [ -z "$TARGET" ]; then
    TARGET=$(echo "$RAWTARGET" \
      | awk -F'DeviceMountPoint="' '{print $2}' \
      | awk -F'"' '{print $1}')
    local AWKTARGET
    AWKTARGET=$(echo "$TARGET" | sed 's@/@\\/@g')

    FST=$(mount | awk -vORS=" " "\$3 ~ /^${AWKTARGET}\$/ {print \$5}")
    local DEVSIZE DEVUSED DEVAVAIL DEVUSEP
    DEVSIZE=$(df -hP | awk "\$6 ~ /^${AWKTARGET}\$/ {print \$2}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
    DEVUSED=$(df -hP | awk "\$6 ~ /^${AWKTARGET}\$/ {print \$3}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
    DEVAVAIL=$(df -hP | awk "\$6 ~ /^${AWKTARGET}\$/ {print \$4}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
    DEVUSEP=$(df -hP | awk "\$6 ~ /^${AWKTARGET}\$/ {print \$5}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")

    LOGIN=""
    DOMAIN=""
    LOCALDEV=1
  fi

  # If it's a network share (cifs / smb) and not local, try mounting for stats
  if [ "$FST" == "cifs" ] || [ "$FST" == "smb" ] && [ "$LOCALDEV" != "1" ]; then
    local MPOINT AWKMPOINT DEVSIZE DEVUSED DEVAVAIL DEVUSEP
    if [ -n "$SMBUSER" ] && [ -n "$SMBPWD" ]; then
      MPOINT=$(mktemp -d)
      AWKMPOINT=$(echo "$MPOINT" | sed 's@/@\\/@g')
      mount -t cifs -o username=$SMBUSER,password=$SMBPWD,domain=$DOMAIN "//${TARGET}" "$MPOINT"
      DEVSIZE=$(df -hP | awk "\$6 ~ /^${AWKMPOINT}\$/ {print \$2}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
      DEVUSED=$(df -hP | awk "\$6 ~ /^${AWKMPOINT}\$/ {print \$3}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
      DEVAVAIL=$(df -hP | awk "\$6 ~ /^${AWKMPOINT}\$/ {print \$4}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
      DEVUSEP=$(df -hP | awk "\$6 ~ /^${AWKMPOINT}\$/ {print \$5}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
      umount "$MPOINT"
      rmdir "$MPOINT"
    fi
  fi

  # If it's nfs and not local, try mounting
  if [ "$FST" == "nfs" ] && [ "$LOCALDEV" != "1" ]; then
    local MPOINT AWKMPOINT DEVSIZE DEVUSED DEVAVAIL DEVUSEP
    MPOINT=$(mktemp -d)
    mount -t nfs "$TARGET" "$MPOINT"
    AWKMPOINT=$(echo "$MPOINT" | sed 's@/@\\/@g')
    DEVSIZE=$(df -hP | awk "\$6 ~ /^${AWKMPOINT}\$/ {print \$2}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
    DEVUSED=$(df -hP | awk "\$6 ~ /^${AWKMPOINT}\$/ {print \$3}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
    DEVAVAIL=$(df -hP | awk "\$6 ~ /^${AWKMPOINT}\$/ {print \$4}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
    DEVUSEP=$(df -hP | awk "\$6 ~ /^${AWKMPOINT}\$/ {print \$5}" | sed -e "s/,/./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
    umount "$MPOINT"
    rmdir "$MPOINT"
  fi

  ######################################
  # Step 4: parse backup job metrics
  ######################################
  local PROCESSED READ TRANSFERRED SPEED SOURCELOAD SOURCEPLOAD NETLOAD TARGETLOAD BOTTLENECK
  PROCESSED=$(echo "$DETAILS" | awk -F'processed_data_size_bytes="' '{print $2}' | awk -F'"' '{print $1}')
  PROCESSED=$(awk "BEGIN {printf \"%.1f\n\", $PROCESSED/1024/1024/1024}")" GB"

  READ=$(echo "$DETAILS" | awk -F'read_data_size_bytes="' '{print $2}' | awk -F'"' '{print $1}')
  READ=$(awk "BEGIN {printf \"%.1f\n\", $READ/1024/1024/1024}")" GB"

  TRANSFERRED=$(echo "$DETAILS" | awk -F'transferred_data_size_bytes="' '{print $2}' | awk -F'"' '{print $1}')
  if [ -n "$TRANSFERRED" ] && [ "$TRANSFERRED" -gt 1073741824 ] 2>/dev/null; then
    TRANSFERRED=$(awk "BEGIN {printf \"%.1f\n\", $TRANSFERRED/1024/1024/1024}")" GB"
  else
    TRANSFERRED=$(awk "BEGIN {printf \"%.0f\n\", $TRANSFERRED/1024/1024}")" MB"
  fi

  SPEED=$(echo "$DETAILS" | awk -F'processing_speed="' '{print $2}' | awk -F'"' '{print $1}')
  SPEED=$(awk "BEGIN {printf \"%.1f\n\", $SPEED/1024/1024}")

  SOURCELOAD=$(echo "$DETAILS" | awk -F'source_read_load="' '{print $2}' | awk -F'"' '{print $1}')
  SOURCEPLOAD=$(echo "$DETAILS" | awk -F'source_processing_load="' '{print $2}' | awk -F'"' '{print $1}')
  NETLOAD=$(echo "$DETAILS" | awk -F'network_load="' '{print $2}' | awk -F'"' '{print $1}')
  TARGETLOAD=$(echo "$DETAILS" | awk -F'target_write_load="' '{print $2}' | awk -F'"' '{print $1}')

  # Bottleneck logic
  BOTTLENECK=""
  if [ -n "$SOURCELOAD" ] && [ -n "$SOURCEPLOAD" ] && [ -n "$NETLOAD" ] && [ -n "$TARGETLOAD" ]; then
    if [ "$SOURCELOAD" -ge "$SOURCEPLOAD" ] && [ "$SOURCELOAD" -ge "$NETLOAD" ] && [ "$SOURCELOAD" -ge "$TARGETLOAD" ]; then
      BOTTLENECK="Source"
    fi
    if [ "$SOURCEPLOAD" -gt "$SOURCELOAD" ] && [ "$SOURCEPLOAD" -gt "$NETLOAD" ] && [ "$SOURCEPLOAD" -gt "$TARGETLOAD" ]; then
      BOTTLENECK="Source CPU"
    fi
    if [ "$NETLOAD" -gt "$SOURCELOAD" ] && [ "$NETLOAD" -gt "$SOURCEPLOAD" ] && [ "$NETLOAD" -gt "$TARGETLOAD" ]; then
      BOTTLENECK="Network"
    fi
    if [ "$TARGETLOAD" -gt "$SOURCELOAD" ] && [ "$TARGETLOAD" -gt "$SOURCEPLOAD" ] && [ "$TARGETLOAD" -gt "$NETLOAD" ]; then
      BOTTLENECK="Target"
    fi
  fi

  ######################################
  # Step 5: Duration, timestamps
  ######################################
  local DUR DURATIONSEC DURATIONMIN DURATIONHOUR DURATION START END STIME ETIME
  let DUR=ENDTIME-STARTTIME
  let DURATIONSEC=DUR%60
  let DURATIONMIN=\(DUR-DURATIONSEC\)/60%60
  let DURATIONHOUR=\(DUR-DURATIONSEC-\(DURATIONMIN*60\)\)/3600
  DURATION=$(printf "%d:%02d:%02d\n" $DURATIONHOUR $DURATIONMIN $DURATIONSEC)

  START=$(date -d "@$STARTTIME" +"%A, %d %B %Y %H:%M:%S")
  END=$(date -d "@$ENDTIME" +"%A, %d.%m.%Y %H:%M:%S")
  STIME=$(date -d "@$STARTTIME" +"%H:%M:%S")
  ETIME=$(date -d "@$ENDTIME"   +"%H:%M:%S")

  ######################################
  # Step 6: State -> success/warning/fail
  ######################################
  local SUCCESS ERROR WARNING BGCOLOR STAT
  SUCCESS=0
  ERROR=0
  WARNING=0
  if [ "$STATE" == "6" ]; then
    SUCCESS=1; BGCOLOR="#00B050"; STAT="Success";
    if [ $INFOMAIL -eq 1 ]; then
      SENDM=1
    fi
  fi
  if [ "$STATE" == "7" ]; then
    ERROR=1; BGCOLOR="#fb9895"; STAT="Failed";
    if [ $INFOMAIL -ge 1 ]; then
      SENDM=1
    fi
  fi
  if [ "$STATE" == "9" ]; then
    WARNING=1; BGCOLOR="#fbcb95"; STAT="Warning";
    if [ $INFOMAIL -le 2 ]; then
      SENDM=1
    fi
  fi

  # If we aren't sending mail at all, skip
  if [ $SENDM -ne 1 ]; then
    return
  fi

  ######################################
  # Step 7: Build the HTML email
  ######################################
  local TEMPFILE
  TEMPFILE=$(mktemp)

  local HN
  HN=${HOSTNAME^^}

  # Build a subject that includes the job name
  local SUBJECT
  SUBJECT=$(echo "[$STAT] $HN - $START ($THISJOBNAME)" | base64 -w0)

  # Basic mail headers:
  {
    echo "From: $EMAILFROM"
    echo "To: $EMAILTO"
    echo "Subject: =?UTF-8?B?$SUBJECT?="
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/html; charset=utf-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo ""
  } > "$TEMPFILE"

  # Insert the template, do variable substitutions
  sed -e "s/XXXJOBNAMEXXX/$THISJOBNAME/g" \
      -e "s/XXXHOSTNAMEXXX/$HN/g" \
      -e "s/XXXSTATXXX/$STAT/g" \
      -e "s/XXXBGCOLORXXX/$BGCOLOR/g" \
      -e "s/XXXBACKUPDATETIMEXXX/$START/g" \
      -e "s/XXXSUCCESSXXX/$SUCCESS/g" \
      -e "s/XXXERRORXXX/$ERROR/g" \
      -e "s/XXXWARNINGXXX/$WARNING/g" \
      -e "s/XXXSTARTXXX/$STIME/g" \
      -e "s/XXXENDXXX/$ETIME/g" \
      -e "s/XXXDATAREADXXX/$READ/g" \
      -e "s/XXXREADXXX/$READ/g" \
      -e "s/XXXTRANSFERREDXXX/$TRANSFERRED/g" \
      -e "s/XXXDURATIONXXX/$DURATION/g" \
      -e "s/XXXSTATUSXXX/$STAT/g" \
      -e "s/XXXTOTALSIZEXXX/$PROCESSED/g" \
      -e "s/XXXBOTTLENECKXXX/$BOTTLENECK/g" \
      -e "s|XXXDETAILSXXX|$ERRLOG|g" \
      -e "s/XXXRATEXXX/$SPEED MB\/s/g" \
      -e "s/XXXBACKUPSIZEXXX/$TRANSFERRED/g" \
      -e "s/XXXAGENTXXX/$AGENT/g" \
      -e "s|XXXTARGETXXX|$TARGET|g" \
      -e "s|XXXFSTXXX|$FST|g" \
      -e "s|XXXLOGINXXX|$LOGIN|g" \
      -e "s|XXXDOMAINXXX|$DOMAIN|g" \
      -e "s|XXXVERSIONXXX|$VERSION|g" \
      -e "s|XXXAKTVERSIONXXX|$AKTVERSION|g" \
      -e "s|XXXDISKSIZEXXX|$DEVSIZE|g" \
      -e "s|XXXDISKUSEDXXX|$DEVUSED|g" \
      -e "s|XXXDISKAVAILXXX|$DEVAVAIL|g" \
      -e "s|XXXDISKUSEPXXX|$DEVUSEP|g" \
      "$HTMLTEMPLATE" >> "$TEMPFILE"

  ######################################
  # Step 8: Send the email
  ######################################
  if [ $USECURL -eq 1 ]; then
    local CURLPARAMS=""
    if [ $CURLSTARTTLS -eq 1 ]; then
      CURLPARAMS="$CURLPARAMS --ssl-reqd"
    fi
    if [ $CURLINSECURE -eq 1 ]; then
      CURLPARAMS="$CURLPARAMS --insecure"
    fi
    $CURL -sS \
      --url "$CURLSMTPSERVER" \
      --mail-from "$EMAILFROM" \
      --mail-rcpt "$EMAILTO" \
      --upload-file "$TEMPFILE" \
      ${CURLUSERNAME:+-u $CURLUSERNAME:"$CURLPASSWORD"} \
      $CURLPARAMS
  else
    cat "$TEMPFILE" | $SENDMAIL -f "$EMAILFROM" -t
  fi

  rm -f "$TEMPFILE"
}

##################################################
# If not running in --bg, but started from veeamjobman,
# re-run in background
##################################################
if [ "$1" != "--bg" ] && [ "$STARTEDFROM" == "veeamjobman" ]; then
  nohup "$0" --bg >/dev/null 2>/dev/null &
  exit
fi

##################################################
# MAIN: Loop over each job in $JOBS
##################################################
for oneJobName in "${JOBS[@]}"; do
  # Trim whitespace
  oneJobName="$(echo "$oneJobName" | xargs)"
  logger -t vee-mail "Processing job: [$oneJobName]"
  send_job_mail "$oneJobName"
done

exit 0

