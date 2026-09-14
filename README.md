`ocserv` 自动安装脚本，适用系统: Ubuntu 18.04+/20.04+/22.04+, Debian 10+

下载脚本:
```
curl -O https://raw.githubusercontent.com/DG9Jww/ocserv-auto/refs/heads/main/ocserv-install.sh
```


加权限:
```
chmod +x ocserv-install.sh
```

运行:
```
./ocserv-install.sh
```

**添加用户**   
```ocpasswd -c /etc/ocserv/ocpasswd newuser```
提示输入密码即可

**修改密码**   
修改密码和添加用户使用同样的命令,输入的密码为新密码

**删除用户**   
`ocpasswd -c /etc/ocserv/ocpasswd -d user1`

**查看已有用户**   
`cat /etc/ocserv/ocpasswd`

**查看服务器当前提供的证书**  
`openssl x509 -in /etc/letsencrypt/live/*/fullchain.pem -noout -dates` 

**Show online users**   
`occtl show users`

**Disconnect online users**   
`occtl disconnect id 5208`

**Certbot check validation of certification**   
`certbot certificates` 

**Check the certificate that ocserv is using**   
`echo | openssl s_client -connect <ipaddr>:<port> 2>/dev/null | openssl x509 -noout -dates` 

**Check the ocserv running log**   
`journalctl -u ocserv --since "10 minutes ago"`
