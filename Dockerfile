ARG URL_CR_PROXY 
ARG KERNEL_NAME

FROM ${URL_CR_PROXY}metacubex/mihomo:latest

# ADD  https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz /clash.gz

# RUN gzip -dc /clash.gz > /clash && chmod +x /clash
ENTRYPOINT [ "/${KERNEL_NAME}" ]

CMD [ "-d", "/root/.config/${KERNEL_NAME}", "-f", "/root/.config/${KERNEL_NAME}/config.yaml" ]
