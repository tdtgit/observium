# Test-only SNMP agent used by scripts/smoke-compose.sh.
#
# It stands in for a monitored host so the smoke test can use the real
# add_device.php path (SNMP reachability, OS detection, device insert) instead
# of inserting rows directly. It is never part of the published image.
FROM alpine:3

RUN apk add --no-cache net-snmp

COPY snmpd.conf /etc/snmp/snmpd.conf

EXPOSE 161/udp

CMD ["snmpd", "-f", "-Lo", "-c", "/etc/snmp/snmpd.conf"]
