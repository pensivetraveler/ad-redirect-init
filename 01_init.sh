sudo dnf update -y
sudo dnf install -y httpd mod_ssl
sudo systemctl enable --now httpd
sudo dnf update -y
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
sudo dnf install -y python3-certbot python3-certbot-apache
sudo dnf install -y whois
sudo dnf install -y git
certbot-3 --version
sudo systemctl enable --now httpd
sudo ss -ltnp | grep :80 || sudo lsof -i:80
git clone "https://github.com/pensivetraveler/cf-redirect.git"