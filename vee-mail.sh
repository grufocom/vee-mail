#!/bin/bash

VERSION=0.5.30
HDIR=$(dirname "$0")
DEBUG=0
INFOMAIL=1
# INFOMAIL 1=ALWAYS (DEFAULT), 2=WARN, 3=ERROR
SENDM=0

if [[ $EUID -ne 0 ]]; then
 echo "This script must be run as root" 
 logger -t vee-mail "This script must be run as root"
 exit 1
fi

. $HDIR/vee-mail.config

if [ "X$SKIPVERSIONCHECK" == "X0" ]; then
 CURL=$(type -p curl)
 if [ "$CURL" ]; then
  AKTVERSION=$($CURL -m2 -f -s https://www.grufo.com/vee_mail.version)
  if [ "$AKTVERSION" ]; then
   if [ ! "$VERSION" == "$AKTVERSION" ]; then
    AKTVERSION="\(new Vee-Mail version $AKTVERSION available\)"
    logger -t vee-mail "new Vee-Mail version $AKTVERSION available"
   else
    AKTVERSION=""
   fi
  fi
 else
  AKTVERSION="\(you need curl to use the upgrade check, please install\)"
 fi
else
 VERSION="$VERSION \(upgrade check disabled\)"
fi

STARTEDFROM=$(ps -p $PPID -hco cmd)
if [ "$1" == "--bg" ]; then
 if [ "$STARTEDFROM" == "veeamjobman" ]; then
  logger -t vee-mail "waiting for 30 seconds"
  sleep 30
 fi
fi

VC=$(which veeamconfig)
if [ ! "$VC" ]; then
 echo "No Veeam Agent for Linux installed!"
 logger -t vee-mail "No Veeam Agent for Linux installed!"
 exit
fi

YUM=$(which yum)

SQLITE=$(which sqlite3)
if [ "$SQLITE" != "/usr/bin/sqlite3" ] && [ "$SQLITE" != "/bin/sqlite3" ]; then
 if [ "$YUM" ]; then
  yum install -y sqlite3
 else
  apt-get install -y sqlite3
 fi
fi

BC=$(which bc)
if [ "$BC" != "/usr/bin/bc" ] && [ "$BC" != "/bin/bc" ]; then
 if [ "$YUM" ]; then
  yum install -y bc
 else
  apt-get install -y bc
 fi
fi

AGENT=$($VC -v)
# get last session id
SESSID=$($VC session list|grep -v "Total amount"|tail -1|awk '{print $3}')
SESSID=${SESSID:1:${#SESSID}-2}

# state 1=Running, 6=Success, 7=Failed, 9=Warning
# get data from sqlite db
SESSDATA=$(sqlite3 /var/lib/veeam/veeam_db.sqlite  "select start_time, end_time, state, progress_details, job_id from JobSessions order by start_time DESC limit 1;")

STARTTIME=$(echo $SESSDATA|awk -F'|' '{print $1}')
ENDTIME=$(echo $SESSDATA|awk -F'|' '{print $2}')
STATE=$(echo $SESSDATA|awk -F'|' '{print $3}')
DETAILS=$(echo $SESSDATA|awk -F'|' '{print $4}')
JOBID=$(echo $SESSDATA|awk -F'|' '{print $5}')

if [ $DEBUG -gt 0 ]; then
 echo -e -n "STARTTIME: $STARTTIME, ENDTIME: $ENDTIME, STATE: $STATE, JOBID: $JOBID\nDETAILS: $DETAILS\n"
 logger -t vee-mail "STARTTIME: $STARTTIME, ENDTIME: $ENDTIME, STATE: $STATE, JOBID: $JOBID\nDETAILS: $DETAILS"
fi

if [ "$JOBID" ]; then
 RAWTARGET=$(sqlite3 /var/lib/veeam/veeam_db.sqlite "SELECT a1.options FROM BackupRepositories AS a1 LEFT JOIN BackupJobs AS a2 ON a1.id=a2.repository_id WHERE a2.id=\"$JOBID\"")
 TARGET=$(echo $RAWTARGET|awk -F'Address="' '{print $2}'|awk -F'"' '{print $1}'|sed -e "s/^\/\///g")
 FST=$(echo $RAWTARGET|awk -F'FsType="' '{print $2}'|awk -F'"' '{print $1}')
 LOGIN=$(echo $RAWTARGET|awk -F'Login="' '{print $2}'|awk -F'"' '{print $1}')
 DOMAIN=$(echo $RAWTARGET|awk -F'Domain="' '{print $2}'|awk -F'"' '{print $1}')
 if [ $DEBUG -gt 0 ]; then
  echo -e -n "TARGET: $TARGET, FST: $FST, LOGIN: $LOGIN, DOMAIN: $DOMAIN\n"
  logger -t vee-mail "TARGET: $TARGET, FST: $FST, LOGIN: $LOGIN, DOMAIN: $DOMAIN"
 fi
 if [ ! "$TARGET" ]; then
  TARGET=$(echo $RAWTARGET|awk -F'DeviceMountPoint="' '{print $2}'|awk -F'"' '{print $1}')
  FST=$(mount |grep " $TARGET "|awk '{print $5}')
  FSD=$(mount |grep " $TARGET "|awk '{print $1}')
  # Filesystem      Size  Used Avail Use% Mounted on
  DEVSIZE=$(df -hP|grep "$TARGET$"|awk '{print $2}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
  DEVUSED=$(df -hP|grep "$TARGET$"|awk '{print $3}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
  DEVAVAIL=$(df -hP|grep "$TARGET$"|awk '{print $4}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
  DEVUSEP=$(df -hP|grep "$TARGET$"|awk '{print $5}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
  LOGIN=""
  DOMAIN=""
  LOCALDEV=1
 fi
 if [ "$FST" == "cifs" ] || [ "$FST" == "smb" ] && [ "$LOCALDEV" != "1" ]; then
  if [ "$SMBUSER" ] && [ "$SMBPWD" ]; then
   MPOINT=$(mktemp -d)
   mount -t cifs -o username=$SMBUSER,password=$SMBPWD,domain=$DOMAIN //$TARGET $MPOINT
   # Filesystem      Size  Used Avail Use% Mounted on
   DEVSIZE=$(df -hP|grep "$MPOINT$"|awk '{print $2}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
   DEVUSED=$(df -hP|grep "$MPOINT$"|awk '{print $3}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
   DEVAVAIL=$(df -hP|grep "$MPOINT$"|awk '{print $4}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
   DEVUSEP=$(df -hP|grep "$MPOINT$"|awk '{print $5}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
   umount $MPOINT
   rmdir $MPOINT
  fi
 fi
 if [ "$FST" == "nfs" ] && [ "$LOCALDEV" != "1" ]; then
  MPOINT=$(mktemp -d)
  mount -t nfs $TARGET $MPOINT
  # Filesystem      Size  Used Avail Use% Mounted on
  DEVSIZE=$(df -hP|grep "$MPOINT$"|awk '{print $2}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
  DEVUSED=$(df -hP|grep "$MPOINT$"|awk '{print $3}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
  DEVAVAIL=$(df -hP|grep "$MPOINT$"|awk '{print $4}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
  DEVUSEP=$(df -hP|grep "$MPOINT$"|awk '{print $5}'|sed -e "s/,/\./g" -e "s/M/ M/g" -e "s/G/ G/g" -e "s/T/ T/g" -e "s/P/ P/g")
  umount $MPOINT
  rmdir $MPOINT
 fi
fi

if [ ! "$1" == "--bg" ] && [ "$STARTEDFROM" == "veeamjobman" ]; then 
 nohup $0 --bg >/dev/null 2>/dev/null &
 exit
fi

if [ "$STATE" == "6" ]; then
 SUCCESS=1; BGCOLOR="#00B050"; STAT="Success";
 if [ $INFOMAIL -eq 1 ]; then
  SENDM=1
 fi
else
 SUCCESS=0;
fi
if [ "$STATE" == "7" ]; then
 ERROR=1; BGCOLOR="#fb9895"; STAT="Failed";
 if [ $INFOMAIL -ge 1 ]; then
  SENDM=1
 fi
else
 ERROR=0;
fi
if [ "$STATE" == "9" ]; then
 WARNING=1; BGCOLOR="#fbcb95"; STAT="Warning";
 if [ $INFOMAIL -le 2 ]; then
  SENDM=1
 fi
else
 WARNING=0;
fi

PROCESSED=$(echo $DETAILS|awk -F'processed_data_size_bytes="' '{print $2}'|awk -F'"' '{print $1}')
PROCESSED=$($BC <<< "scale=1; $PROCESSED/1024/1024/1024")" GB"
READ=$(echo $DETAILS|awk -F'read_data_size_bytes="' '{print $2}'|awk -F'"' '{print $1}')
READ=$($BC <<< "scale=1; $READ/1024/1024/1024")" GB"
TRANSFERRED=$(echo $DETAILS|awk -F'transferred_data_size_bytes="' '{print $2}'|awk -F'"' '{print $1}')
if [ $DEBUG -gt 0 ]; then
 echo -e -n "PROCESSED: $PROCESSED, READ: $READ, TRANSFERRED: $TRANSFERRED\n"
 logger -t vee-mail "PROCESSED: $PROCESSED, READ: $READ, TRANSFERRED: $TRANSFERRED"
fi
if [ $TRANSFERRED -gt 1073741824 ]; then
 TRANSFERRED=$($BC <<< "scale=1; $TRANSFERRED/1024/1024/1024")" GB"
else
 TRANSFERRED=$($BC <<< "scale=0; $TRANSFERRED/1024/1024")" MB"
fi
SPEED=$(echo $DETAILS|awk -F'processing_speed="' '{print $2}'|awk -F'"' '{print $1}')
SPEED=$($BC <<< "scale=1; $SPEED/1024/1024")
SOURCELOAD=$(echo $DETAILS|awk -F'source_read_load="' '{print $2}'|awk -F'"' '{print $1}')
SOURCEPLOAD=$(echo $DETAILS|awk -F'source_processing_load="' '{print $2}'|awk -F'"' '{print $1}')
NETLOAD=$(echo $DETAILS|awk -F'network_load="' '{print $2}'|awk -F'"' '{print $1}')
TARGETLOAD=$(echo $DETAILS|awk -F'target_write_load="' '{print $2}'|awk -F'"' '{print $1}')
if [ $DEBUG -gt 0 ]; then
 echo -e -n "SPEED: $SPEED, SOURCELOAD: $SOURCELOAD, NETLOAD: $NETLOAD, TARGETLOAD: $TARGETLOAD\n"
 logger -t vee-mail "SPEED: $SPEED, SOURCELOAD: $SOURCELOAD, NETLOAD: $NETLOAD, TARGETLOAD: $TARGETLOAD"
fi

if [ "$SOURCELOAD" -gt "$SOURCEPLOAD" ] && [ "$SOURCELOAD" -gt "$NETLOAD" ] && [ "$SOURCELOAD" -gt "$TARGETLOAD" ]; then
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

DURATION=$(date -d "0 $ENDTIME sec - $STARTTIME sec" +"%H:%M:%S")
START=$(date -d "@$STARTTIME" +"%A, %d %B %Y %H:%M:%S")
END=$(date -d "@$ENDTIME" +"%A, %d.%m.%Y %H:%M:%S")
STIME=$(date -d "@$STARTTIME" +"%H:%M:%S")
ETIME=$(date -d "@$ENDTIME" +"%H:%M:%S")

if [ $DEBUG -gt 0 ]; then
 echo -e -n "DURATION: $DURATION, START: $START, END: $END, STIME: $STIME, ETIME: $ETIME\n"
 logger -t vee-mail "DURATION: $DURATION, START: $START, END: $END, STIME: $STIME, ETIME: $ETIME"
fi

# get session error
ERRLOG=$($VC session log --id $SESSID|egrep 'error|warn'|sed ':a;N;$!ba;s/\n/<br>/g'|sed -e "s/ /\&nbsp;/g")
ERRLOG=$(printf "%q" $ERRLOG)
if [ "$ERRLOG" == "''" ]; then
 ERRLOG=""
fi

if [ $DEBUG -gt 0 ]; then
 echo -e -n "ERRLOG: $ERRLOG\n"
 logger -t vee-mail "ERRLOG: $ERRLOG"
fi

# create temp file for mail
TEMPFILE=$(mktemp)

# uppercase hostname
HN=${HOSTNAME^^}

# build email
echo "From: $EMAILFROM
To: $EMAILTO
Subject: =?UTF-8?Q?[$STAT] $HN - $START?=
MIME-Version: 1.0
Content-Type: text/html; charset=utf-8
Content-Transfer-Encoding: 8bit

" > $TEMPFILE

# debug output
if [ $DEBUG -gt 0 ]; then
 echo -e -n "HN: $HN\nSTAT: $STAT\nBGCOLOR: $BGCOLOR\nSTART: $START\nSUCCESS: $SUCCESS\nERROR: $ERROR\nWARNING: $WARNING\nSTIME: $STIME\nETIME: $ETIME\nREAD: $READ\nTRANSFERRED: $TRANSFERRED\nDURATION: $DURATION\nPROCESSED: $PROCESSED\nBOTTLENECK: $BOTTLENECK\nERRLOG: $ERRLOG\nSPEED: $SPEED\nTARGET: $TARGET\nFST: $FST\nLOGIN: $LOGIN\nDOMAIN: $DOMAIN\n DEVUSEP: $DEVUSEP\n"
 logger -t vee-mail "HN: $HN; STAT: $STAT; BGCOLOR: $BGCOLOR; START: $START; SUCCESS: $SUCCESS; ERROR: $ERROR; WARNING: $WARNING; STIME: $STIME; ETIME: $ETIME; READ: $READ; TRANSFERRED: $TRANSFERRED; DURATION: $DURATION; PROCESSED: $PROCESSED; BOTTLENECK: $BOTTLENECK; ERRLOG: $ERRLOG; SPEED: $SPEED; TARGET: $TARGET; FST: $FST; LOGIN: $LOGIN; DOMAIN: $DOMAIN;  DEVUSEP: $DEVUSEP"
fi

sed -e "s/XXXHOSTNAMEXXX/$HN/g" -e "s/XXXSTATXXX/$STAT/g" -e "s/XXXBGCOLORXXX/$BGCOLOR/g" -e "s/XXXBACKUPDATETIMEXXX/$START/g" -e "s/XXXSUCCESSXXX/$SUCCESS/g" -e "s/XXXERRORXXX/$ERROR/g" -e "s/XXXWARNINGXXX/$WARNING/g" -e "s/XXXSTARTXXX/$STIME/g" -e "s/XXXENDXXX/$ETIME/g" -e "s/XXXDATAREADXXX/$READ/g" -e "s/XXXREADXXX/$READ/g" -e "s/XXXTRANSFERREDXXX/$TRANSFERRED/g" -e "s/XXXDURATIONXXX/$DURATION/g" -e "s/XXXSTATUSXXX/$STAT/g" -e "s/XXXTOTALSIZEXXX/$PROCESSED/g" -e "s/XXXBOTTLENECKXXX/$BOTTLENECK/g" -e "s|XXXDETAILSXXX|$ERRLOG|g" -e "s/XXXRATEXXX/$SPEED MB\/s/g" -e "s/XXXBACKUPSIZEXXX/$TRANSFERRED/g" -e "s/XXXAGENTXXX/$AGENT/g" -e "s|XXXTARGETXXX|$TARGET|g" -e "s|XXXFSTXXX|$FST|g" -e "s|XXXLOGINXXX|$LOGIN|g" -e "s|XXXDOMAINXXX|$DOMAIN|g" -e "s|XXXVERSIONXXX|$VERSION|g" -e "s|XXXAKTVERSIONXXX|$AKTVERSION|g" -e "s|XXXDISKSIZEXXX|$DEVSIZE|g" -e "s|XXXDISKUSEDXXX|$DEVUSED|g" -e "s|XXXDISKAVAILXXX|$DEVAVAIL|g" -e "s|XXXDISKUSEPXXX|$DEVUSEP|g" $HTMLTEMPLATE >> $TEMPFILE 
# send email
if [ $SENDM -eq 1 ]; then
 cat $TEMPFILE | sendmail -f $EMAILFROM -t
fi
rm $TEMPFILE

exit
