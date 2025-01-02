Подключись к серверу и по очереди выполни эти команды (тогда тунелирование будет скрыто)


1)
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

if [ $? -ne 0 ]; then
  echo "Не удалось добавить правило iptables MASQUERADE" >&2
else
  echo "MASQUERADE успешно добавлен для интерфейса eth0"
fi


2) 
sudo iptables -A INPUT -p icmp -j DROP
sudo iptables -A OUTPUT -p icmp -j DROP
if [ $? -ne 0 ]; then
  echo "Не удалось добавить правила iptables для блокировки ICMP" >&2
else
  echo "ICMP-запросы блокированы"
fi

3)
sudo ip link set dev eth0 mtu 1500
if [ $? -ne 0 ]; then
  echo "Не удалось установить MTU=1500 на интерфейсе eth0" >&2
else
  echo "MTU=1500 установлен на интерфейсе eth0"
fi
