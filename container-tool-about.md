# 安装NVIDIA Container Toolkit
Installing the NVIDIA Container Toolkit
[https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html#installing-with-apt](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html#installing-with-apt)
  
# 配置docker服务
config docker
```bash
nvidia-ctk runtime configure --runtime=docker
```

执行以上命令后，会自动添加
```bash

root@cisdi-4090-1:/home/cisdi/nvidia# cat /etc/docker/daemon.json

{

    "registry-mirrors": [

        "https://hub.geekery.cn",

        "https://docker.m.daocloud.io",

        "https://noohub.ru",

        "https://huecker.io",

        "https://dockerhub.timeweb.cloud"

    ],

    "runtimes": {

        "nvidia": {

            "args": [],

            "path": "nvidia-container-runtime"

        }

    }

}
```

  
重启docker server服务
```bash
systemctl daemon-reload && systemctl restart docker
```

因为使用containerd,所以使用containerd的配置：
```bash
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
```

