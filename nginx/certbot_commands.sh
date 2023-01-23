#!/bin/bash

docker exec nginx mkdir -p /etc/nginx/html \
&& docker exec -it nginx \
    certbot certonly \
    --nginx \
    -w /etc/nginx/html \
    -d krispharper.com \
    -d www.krispharper.com \
    -d nas.krispharper.com \
    -d plex.krispharper.com \
    -d tautulli.krispharper.com \
    -d moviematch.krispharper.com \
    -d transmission.krispharper.com \
    -d sonarr.krispharper.com \
    -d jackett.krispharper.com \
    -d radarr.krispharper.com \
    -d crashplan.krispharper.com \
    -d pi-hole.krispharper.com \
    -d paulaclareharper.krispharper.com \
    -d paulaclareharper.com \
    -d www.paulaclareharper.com \
    -d musicscholarshipatadistance.krispharper.com \
    -d swiftconference2021.com \
    -d musicandtheinternet.co \
&& sudo systemctl restart nginx
