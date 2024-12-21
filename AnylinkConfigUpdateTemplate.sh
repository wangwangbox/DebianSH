#!/bin/bash

remote_file_url=https://alupdate.x.vip/conf/profile.xml
local_file_path=/root/conf/profile.xml
local_file_bak_path=/root/conf/profile.temp.xml
temp_file=$(mktemp)
wget --no-check-certificate -O $temp_file $remote_file_url

if [ -s $temp_file ]; then
    LocalFileMD5=$(md5sum "$local_file_path" | awk '{print $1}')
    TempFileMD5=$(md5sum "$temp_file" | awk '{print $1}')
    if [ "$LocalFileMD5" == "$TempFileMD5" ] && [ -f "$local_file_path" ]; then
        echo "文件数据完全相同，无需更新!"
    else
        string1="<AnyConnectProfile"
        string2="</AnyConnectProfile>"
        if grep -q "$string1" $temp_file && grep -q "$string2" $temp_file; then
            cp $local_file_path $local_file_bak_path
            mv $temp_file $local_file_path
            restart_output=$(docker restart anylink 2>&1)
            if [ $? -eq 0 ]; then
                echo "Docker容器重启成功!"
            else
                echo "Docker容器重启失败: $restart_output"
                mv $local_file_bak_path $local_file_path
            fi
            rm $local_file_bak_path
        else
            echo "验证文件数据失败!"
        fi
    fi
else
    echo "文件下载失败!"
    rm $temp_file
fi

wget --no-check-certificate -O certificate.zip https://alupdate.x.vip/conf/vpn_cert.zip

# 验证压缩包的完整性
unzip -t certificate.zip
if [ $? -eq 0 ]; then
    echo "压缩包完整性验证通过"

    # 解压压缩包
    unzip -o certificate.zip

    # 判断解压是否成功
    if [ $? -eq 0 ]; then
        echo "压缩包解压成功"

        # 检查证书和密钥是否需要替换
        if ! cmp -s /root/vpn_cert/vpn_cert.crt /root/conf/vpn_cert.crt || ! cmp -s /root/vpn_cert/vpn_cert.key /root/conf/vpn_cert.key; then
            echo "证书或密钥内容有变化，进行替换"

            # 替换证书和密钥
            mv /root/vpn_cert/vpn_cert.crt /root/conf/
            mv /root/vpn_cert/vpn_cert.key /root/conf/

            # 重启容器
            restart_output=$(docker restart anylink 2>&1)
            if [ $? -eq 0 ]; then
                echo "Docker容器重启成功!"
            else
                echo "Docker容器重启失败: $restart_output"
            fi
        else
            echo "证书和密钥内容没有变化，无需重启容器"
        fi
    else
        echo "压缩包解压失败"
    fi
else
    echo "压缩包完整性验证失败"
fi

# 删除下载的压缩包
rm certificate.zip

