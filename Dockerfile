ARG URL_CR_PROXY

FROM ${URL_CR_PROXY}metacubex/mihomo:latest

ADD  https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz /clash.gz

RUN gzip -dc /clash.gz > /clash && chmod +x /clash

ENTRYPOINT [ "/mihomo" ]

CMD [ "-d", "/root/.config/mihomo", "-f", "/root/.config/mihomo/config.yaml" ]
