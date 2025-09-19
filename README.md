# vee-mail
Simple Script to get Mails from Free Veeam Agent for Linux

vee-mail uses the sqlite database which get's filled from Veeam Agent for Linux Free in /var/lib/veeam/veeam_db.sqlite.
The Linux version from Veeam Agent does not send notification e-mails like the windows version.
So this script reads the data from the sqlite database and fills it into the template file which get's sent per mail to you.

# Dependencies

veeam  
sqlite3 (>= 3.7.0)  
curl (to send mail and/or to check for updates)  
sendmail (your system should be able to send mails with sendmail command - postfix, bsd-mailx, nullmailer,...)

By default sendmail is used to send the report.  
If you choose to use curl to send the report (USECURL=1 in config file) then sendmail is not necessary and won't be installed.  

# Install

git clone https://github.com/grufocom/vee-mail  
move the directory "vee-mail" to /opt or any other directory you would like to install it into
change vee-mail.config file to your needs.  
chmod +x vee-mail.sh

# Use

You can use the vee-mail script as a post-backup script directly in veeam (Configure - select Job, Advanced/Scripts/Post-Job) or start it manualy after the veeam backup has run:

/opt/vee-mail/vee-mail.sh

# Release notes

## Version 0.6.3
fixes BG_FLAG bug and added some logging - thx to adrianhalid

## Version 0.6.2
fixes command line parameter bug and added -h/--help cli parameter

## Version 0.6.1
fixes bug mounting cifs shares

## Version 0.6.0
adds support for multiple backup jobs

## Version 0.5.49
base64 subject fixes problem with utf8 quoted subject on some mail servers

## Version 0.5.48
use SLEEP variable from config file to wait for veeamjob to finish

## Version 0.5.47
check the version of veeam with veeamconfig command and not dpkg or rpm

## Version 0.5.46
fix for UUID error on SessionID since veeam version 6 release

## Version 0.5.45
fix for new veeam release version 6 (database structure change)

## Version 0.5.44
fixes empty mail body

## Version 0.5.43
get jobname from veeam database and fix disk statistics

## Version 0.5.42
df does not understand regex, so we need a grep to get only the path we need

## Version 0.5.41
df without grep and going into background directly after reading config file

## Version 0.5.40
Fix password issue

## Version 0.5.39
Bugfix version check

## Version 0.5.38
fix message blank line ending header following RFC (fix reception by outlook.com)

## Version 0.5.37
offer use of curl instead of sendmail (sendmail is still the default)

## Version 0.5.36
remove dateutils dependancy

## Version 0.5.35
remove bc dependancy

## Version 0.5.34
new version check against github

## Version 0.5.33
Improve finding session id

## Version 0.5.32
bugfix duration time when it's bigger than 24h

## Version 0.5.31
sendmail get's installed if not already done

## Version 0.5.30
add sender address to sendmail command

## Version 0.5.29
remove trailing slahes from target path (cifs/smb)

## Version 0.5.28
added check for FST is smb - not only cifs

## Version 0.5.27
bugfix latin character in mail subject, switched to 8-bit and utf8

## Version 0.5.26
bugfix SENDM needs to be set

## Version 0.5.23 - 0.5.25
New parameter for info-mails, you can now set when you would like to get an infomail from vee-mail

## Version 0.5.22
Reintegrated background mode

## Version 0.5.21
Just cosmetics

## Version 0.5.20
Increased the time the script waits until veeam backup is finished

## Version 0.5.19
Removed background mode from script

## Version 0.5.18
Added debug messages via syslog (logger-tag: vee-mail)

## Version 0.5.16 & 0.5.17
Changed the way "df" is used for free space on backup device

## Version 0.5.14 & 0.5.15
Added more debugging output

## Version 0.5.13
Bugfix Release - don't mount local device

## Version 0.5.12
Bugfix Release

## Version 0.5.11
Check for root user before execution

## Version 0.5.10
First release on Github with new name "vee-mail"

