FROM nginx:latest

RUN apt-get update \
    && apt-get install -y wget python3 python3-pip libaugeas0 \
    && pip install --upgrade pip \
    && pip install install certbot certbot-nginx \
    && ln -s /opt/certbot/bin/certbot /usr/bin/certbot

COPY nginx.conf /etc/nginx/nginx.conf
