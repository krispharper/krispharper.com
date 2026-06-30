# 0. One-time: create the dir and give cloudflared's nonroot user (UID 65532) write access
mkdir -p cloudflared
sudo chown -R 65532:65532 cloudflared

# 1. Authenticate. Prints a URL — open it in your browser and pick your zone.
#    -it is required here because it's interactive and waits for you. Writes cert.pem.
#docker run -it --rm \
      #-v "$PWD/cloudflared:/home/nonroot/.cloudflared" \
        #cloudflare/cloudflared:latest tunnel login

# 2. Create the tunnel. Writes <UUID>.json and prints the tunnel UUID.
#docker run --rm \
      #-v "$PWD/cloudflared:/home/nonroot/.cloudflared" \
        #cloudflare/cloudflared:latest tunnel create krispharper.com

# 3. Point your hostname at the tunnel (creates the DNS record automatically).
#docker run --rm \
      #-v "$PWD/cloudflared:/home/nonroot/.cloudflared" \
        #cloudflare/cloudflared:latest tunnel route dns krispharper.com krispharper.us

# Or run for all subdomains.
#for h in \
    #krispharper.com www.krispharper.com \
    #nas.krispharper.com plex.krispharper.com overseerr.krispharper.com \
    #tautulli.krispharper.com sonarr.krispharper.com radarr.krispharper.com \
    #transmission.krispharper.com jackett.krispharper.com agregarr.krispharper.com \
    #crashplan.krispharper.com pi-hole.krispharper.com ; do
    #docker run --rm -v "$PWD/cloudflared:/home/nonroot/.cloudflared" cloudflare/cloudflared:latest tunnel route dns krispharper.com "$h"
#done
