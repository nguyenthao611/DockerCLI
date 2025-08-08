#xoá Docker + dữ liệu + cấu hình chỉ bằng một lệnh duy nhất:

sudo apt remove --purge -y docker.io docker-ce docker-ce-cli containerd.io docker-compose-plugin && \
sudo apt autoremove -y --purge && \
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker

#hạy trực tiếp trên server bằng 1 lệnh duy nhất như sau:
bash <(curl -fsSL https://raw.githubusercontent.com/nguyenthao611/DockerCLI/refs/heads/main/setup_docker_stack.sh) \
  --domain yourdomain.com \
  --email you@example.com \
  --with-pma yes \
  --db-name mydb \
  --db-user myuser \
  --db-password mypass \
  --db-root rootpass
