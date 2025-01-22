FROM nginx

RUN apt-get update && \
    apt-get install -y wget unzip git jq procps && \
    rm -rf /var/lib/apt/lists/*
    
COPY start.sh backup.sh restore.sh /app/

WORKDIR /app

RUN chmod +x start.sh backup.sh restore.sh

EXPOSE 80 443

ENTRYPOINT ["/app/start.sh"]
