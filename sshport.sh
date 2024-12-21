#!/bin/bash

# 检查是否以root用户运行
if [ "$EUID" -ne 0 ]; then
  echo "请以root用户运行此脚本"
  exit 1
fi

# 读取用户输入的新端口号
read -p "请输入新的SSH端口号: " new_port

# 检查新端口号是否有效
if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then
  echo "无效的端口号。请输入1到65535之间的数字。"
  exit 1
fi

# 更新ssh配置文件
sshd_config="/etc/ssh/sshd_config"

if grep -q "^#Port 22" $sshd_config; then
  sed -i "s/#Port 22/Port $new_port/" $sshd_config
elif grep -q "^Port " $sshd_config; then
  sed -i "s/^Port .*/Port $new_port/" $sshd_config
else
  echo "Port $new_port" >> $sshd_config
fi

# 添加防火墙规则
if command -v ufw > /dev/null; then
  ufw allow $new_port/tcp
  ufw delete allow 22/tcp
  ufw reload
elif command -v firewall-cmd > /dev/null; then
  firewall-cmd --permanent --add-port=$new_port/tcp
  firewall-cmd --permanent --remove-port=22/tcp
  firewall-cmd --reload
else
  echo "未找到支持的防火墙工具（ufw或firewalld）。尝试使用iptables添加规则。"

  # 添加新的iptables规则
  iptables -A INPUT -p tcp --dport $new_port -j ACCEPT
  iptables -D INPUT -p tcp --dport 22 -j ACCEPT

  # 保存iptables规则
  if [ -f /etc/iptables/rules.v4 ]; then
    iptables-save > /etc/iptables/rules.v4
  elif [ -f /etc/iptables/rules.v6 ]; then
    iptables-save > /etc/iptables/rules.v6
  else
    echo "未找到iptables规则文件，请手动保存规则。"
  fi
fi

# 重启SSH服务
systemctl restart ssh

# 检查SSH服务状态
if systemctl status ssh | grep -q "active (running)"; then
  echo "SSH端口已成功更改为 $new_port 并已重启SSH服务。"
else
  echo "SSH服务未能重启，请检查配置文件。"
fi
