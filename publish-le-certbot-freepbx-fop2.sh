#!/bin/bash
exec 3>&1 4>&2
set -e

[[ ! -f $(which certbot) ]] && echo "Please install certbot, exiting..." && exit 1

MailFrom="no-reply-systemalerts@yourdomain.com"
MailTo="infra-watchdog@yourdomain.com"
DaysToExpiration=15
CertName="phone.yourdomain.com"
Domains="phone.yourdomain.com"
ServicesToResart="httpd fop2"
name="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")"
ScriptLogFile="/var/log/$name.log"

exec 1>$ScriptLogFile 2>&1

trap 'CatchTrap $? $LINENO' ERR

function CatchTrap() {
 if [[ "$1" != "0" ]]; then
  echo -e "Error:"
  MailSubject="[$(hostname)] Certbot [Error] - LetsEncrypt: $CertName"
  MailBody="Error $1 occurred on $2"
  echo -e "$MailSubject\n$MailBody"
  echo -e "$MailBody" | mail -s "$MailSubject" -r $MailFrom $MailTo
 fi
}

function SendEmail() {
 op=$1
 OLD_IFS="$IFS"
 IFS=
 lecert=$(certbot certificates --cert-name $CertName)
 IFS="$OLD_IFS"
 MailBody="Cert Details:\n$lecert"
 MailSubject="[$(hostname)] Certbot - LetsEncrypt Cert $op: $CertName"
 echo -e "Sending email"
 echo -e $MailSubject
 echo -e $MailBody
 echo -e "$MailBody" | mail -s "$MailSubject" -r $MailFrom $MailTo
 echo -e "Email sent"
}

function RestartServices() {
 echo -e "Restarting services $ServicesToResart"
 for service in $ServicesToResart; do
  systemctl restart $service
 done
 SendEmail $1
}

#start
echo -e "Getting currently installed cert from certbot for $CertName"
cert=$(certbot certificates --cert-name $CertName 2>/dev/null)

if [[ "$cert" == *"No certificates found"* ]]; then
 echo -e "$CertName cert is not installed. Installing..."
 certbot certonly --config /etc/letsencrypt/cli.ini \
  --dns-cloudflare --dns-cloudflare-credentials /etc/pki/tls/private/cf.ini \
  --dns-cloudflare-propagation-seconds 20 \
  --cert-name $CertName -d $Domains \
  --verbos \
  --agree-tos

  if [[ -f "/etc/letsencrypt/live/$CertName/cert.pem" ]]; then
   echo -e "$CertName cert is installed."
   RestartServices "Installed"
  fi
else
 echo -e "$CertName cert is installed. Checking if renewal is needed"
 daysvalid=$(certbot certificates --cert-name $CertName 2>/dev/null | \
  grep Expiry | cut -d':' -f6 | cut -d' ' -f2 | xargs)
 if [[ $daysvalid -le $DaysToExpiration ]]; then
  echo -e "$CertName cert renewal is needed. Renewing..."
  certbot renew --config /etc/letsencrypt/cli.ini \
   --cert-name $CertName \
   --force-renewal \
   --verbose
  newdaysvalid=$(certbot certificates --cert-name $CertName 2>/dev/null | \
   grep Expiry | cut -d':' -f6 | cut -d' ' -f2 | xargs)
  if [[ $newdaysvalid -ge $daysvalid ]]; then
   echo -e "$CertName cert is renewed for another $newdaysvalid days."
   RestartServices "Renewed"
  fi
 else
  echo "$CertName cert is valid for another $daysvalid days"
 fi
fi
