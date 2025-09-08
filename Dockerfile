FROM ubuntu:22.04

ENV container=docker
STOPSIGNAL SIGRTMIN+3

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv \
      curl procps ca-certificates \
      && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/local/bin /etc/systemd/system /etc/default

COPY test-monitor.sh /usr/local/bin/test-monitor.sh
COPY test-monitor.service /etc/systemd/system/test-monitor.service
COPY test-monitor.timer /etc/systemd/system/test-monitor.timer
COPY default-test-monitor /etc/default/test-monitor

RUN chmod +x /usr/local/bin/test-monitor.sh

RUN echo '#!/bin/sh\nwhile true; do sleep 60; done' > /usr/local/bin/test && \
    chmod +x /usr/local/bin/test

RUN echo "[Unit]\nDescription=Dummy test process\n\n[Service]\nExecStart=/usr/local/bin/test\nRestart=always\n\n[Install]\nWantedBy=multi-user.target" \
    > /etc/systemd/system/test-simulator.service

RUN systemctl enable test-monitor.timer && \
    systemctl enable test-simulator.service

VOLUME [ "/sys/fs/cgroup" ]
CMD ["/sbin/init"]
