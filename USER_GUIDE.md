# env环境变量修改
`.env`文件中：
```
# 标识在多个租户间唯一，建议使用用户名
OPENCLAW_TENANT=xxx
# 映射的ssh端口，避免冲突
OPENCLAW_SSH_PORT=0.0.0.0:2223
# 映射的前端端口，避免冲突
OPENCLAW_WEB_PORT=0.0.0.0:3002
# 映射的后端端口，避免冲突
OPENCLAW_API_PORT=0.0.0.0:8002
```

# 初始化和启动开发容器环境
bash bootstrap-startup.sh start|restart|stop|status

# vscode或者ssh连接容器环境，端口2223，使用秘钥登录
PC端生成密钥对，ssh-keygen 命令
把公钥给容器开发环境的路径
```
cat ~/.ssh/authorized_keys 
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABfMykJPARhqOUVRqYSRtOSaQ2TtmTLTKCObuHn8Bw5 xxx.com
```
使用自己的私钥进行登录

# 在容器环境启动前后端
在开发环境中
```
cd /home/node/workspace/edge-vision-ops
./scripts/dev-control-plane-frontend.sh start
```
日志查看
```
./scripts/dev-control-plane-frontend.sh logs
```

# 前端访问
```
http://192.168.11.194:{前端端口}
```

# 后端接口访问
```
http://192.168.11.194:{后端端口}/swagger
```
