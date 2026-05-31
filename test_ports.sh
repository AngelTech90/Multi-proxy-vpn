for port in 1080 1081 1082 1083 1084 1085 1086 1087 1088 1089 1090 1091; do printf "P%d: " ${port}; IP=$(timeout 15 
curl --socks5 127.0.0.1:${port} -s https://ifconfig.me 2>/dev/null); [ -n "${IP}" ] && echo "OK ${IP}" || echo "FAIL"; 
done
#!
#!
