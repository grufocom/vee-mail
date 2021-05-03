# vee-mail
Simple Script to get Mails from Free Veeam Agent for Linux

vee-mail uses the sqlite database which get's filled from Veeam Agent for Linux Free in /var/lib/veeam/veeam_db.sqlite.
The Linux version from Veeam Agent does not send notification e-mails like the windows version.
So this script reads the data from the sqlite database and fills it into the template file which get's sent per mail to you.

# Dependencies

veeam  
sqlite3 (>= 3.7.0)  
bc  
curl (only for vee-mail update check)  

# Install

git clone https://github.com/grufocom/vee-mail  
move the directory "vee-mail" to /opt or any other directory you would like to install it into
change vee-mail.confg file to your needs.  
chmod +x vee-mail.sh

# Use

You can use the vee-mail script as a post-backup script directly in veeam (Configure - select Job, Advanced/Scripts/Post-Job) or start it manualy after the veeam backup has run:

/opt/vee-mail/vee-mail.sh

# Release notes

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

