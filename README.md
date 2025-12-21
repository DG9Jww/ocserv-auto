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

如果是使用域名，需要自动续签 Let’s Encrypt Certificate
```
sudo crontab -e
```
写入定时任务
```
0 5 * * * certbot renew --quiet && systemctl restart ocserv
```
