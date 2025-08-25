sudo dnf update -y
sudo dnf install -y httpd mod_ssl
sudo systemctl enable --now httpd
sudo dnf update -y
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
sudo dnf install -y python3-certbot python3-certbot-apache
sudo dnf install -y whois
sudo dnf install -y git
sudo dnf install perl-Digest-SHA -y
# PHP와 자주 쓰는 확장들
sudo dnf install -y php-cli php-fpm php-mbstring php-xml php-json php-opcache php-pdo php-mysqlnd php-gd php-intl php-zip

certbot-3 --version
sudo systemctl enable --now httpd
sudo ss -ltnp | grep :80 || sudo lsof -i:80
git clone "https://github.com/pensivetraveler/cf-redirect.git"