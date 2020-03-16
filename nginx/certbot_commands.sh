#!/bin/bash

docker exec nginx mkdir /etc/nginx/html
docker exec -it nginx certbot-auto certonly --webroot -w /etc/nginx/html -d krispharper.com -d www.krispharper.com -d plex.krispharper.com -d transmission.krispharper.com -d nas.krispharper.com -d paulaclareharper.krispharper.com -d paulaclareharper.com -d www.paulaclareharper.com -d phlex.krispharper.com -d sonarr.krispharper.com -d jackett.krispharper.com -d radarr.krispharper.com -d crashplan.krispharper.com -d musicscholarshipatadistance.com
