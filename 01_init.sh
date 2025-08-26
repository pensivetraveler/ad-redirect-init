sudo dnf update -y
sudo dnf install -y httpd mod_ssl git whois perl-Digest-SHA wget unzip vim htop which
# PHP와 자주 쓰는 확장들
sudo dnf install -y php-cli php-common php-fpm php-mbstring php-xml php-json php-opcache php-pdo php-mysqlnd php-gd php-intl php-zip php-curl php-process php-dom

sudo systemctl enable --now httpd

# certbot 설치
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
sudo dnf install -y python3-certbot python3-certbot-apache

certbot-3 --version
sudo systemctl enable --now httpd
sudo ss -ltnp | grep :80 || sudo lsof -i:80
git clone "https://github.com/pensivetraveler/ad-redirect-init.git"