#!/bin/bash

while true; do
    read -p "请输入新的root密码: " rootpw
    read -p "请再次输入新的root密码: " rootpw_verify
    if [ "$rootpw" = "$rootpw_verify" ]; then
        echo "输入的密码为: [$rootpw]"
        break
    else
        echo "两次输入的密码不一致，请重新输入."
    fi
done

read -p "你将要更改root密码，你确定吗？ (y/n): " confirm
if [ "$confirm" = "y" ]; then
    echo "root:${rootpw}" | chpasswd
    echo "密码已成功更改."
else
    echo "密码未更改."
fi
