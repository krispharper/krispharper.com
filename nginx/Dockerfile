FROM nginx:latest

RUN apt-get update \
    && apt-get install -y wget \
    && wget https://dl.eff.org/certbot-auto \
    && mv certbot-auto /usr/local/bin/certbot-auto \
    && chown root /usr/local/bin/certbot-auto \
    && chmod 0755 /usr/local/bin/certbot-auto \
    && yes | certbot-auto --version

COPY nginx.conf /etc/nginx/nginx.conf
