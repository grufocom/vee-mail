# vee-mail
Simple Script to get Mails from Free Veeam Agent for Linux

vee-mail uses the sqlite database which get's filled from Veeam Agent for Linux Free in /var/lib/veeam/veeam_db.sqlite.
The Linux version from Veeam Agent does not send notification e-mails like the windows version.
So this script reads the data from the sqlite database and fills it into the template file which get's sent per mail to you.

# Dependencies

veeam
sqlite3
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

## Version 0.5.10
First release on Github with new name "vee-mail"

