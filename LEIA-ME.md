# Cluster IA — 2 notebooks Ubuntu ligados por cabo

Baseado no playbook NVIDIA "Connect two Sparks", adaptado para notebooks comuns
(cabo Ethernet direto **ou** cabo USB-C/Thunderbolt entre os dois).

## Arquivos

| Arquivo | Para quê |
|---|---|
| `cluster-ia-setup.sh` | **Script novo.** Configura tudo. Roda em cada notebook. |
| `cluster-ia-limpar.sh` | Desfaz tudo que o script antigo (ou o novo) instalou. |
| `corrigir-usuario-node2.sh` | Só no PC 2: apaga o usuário criado por engano e renomeia o original. |
| `connect-two-nodes.sh` | Script antigo, mantido só como referência. **Não use.** |

Copie os arquivos para os dois notebooks (pendrive, ou `scp`).

## Ordem de execução

### PC 2 primeiro — corrigir o usuário

O nome de usuário precisa ser **igual** nos dois notebooks.

```bash
sudo bash corrigir-usuario-node2.sh
```

Ele pergunta: seu usuário original, o usuário criado por engano (será apagado)
e o nome final (o mesmo do PC 1). A troca acontece no **próximo boot**, porque
o Linux não deixa renomear um usuário que está logado. Aceite reiniciar.
Depois entre com o nome novo e a **mesma senha de sempre**.

### Nos dois PCs — limpar o que o script antigo fez

```bash
sudo bash cluster-ia-limpar.sh
```

Responda às perguntas. O `~/ia-venv` (PyTorch, 2 GB) pode ser mantido; o setup
novo reaproveita. Depois reinicie: `sudo reboot`.

### Nos dois PCs — configurar

No notebook 1:

```bash
sudo bash cluster-ia-setup.sh 1
```

No notebook 2:

```bash
sudo bash cluster-ia-setup.sh 2
```

O script mostra as interfaces de rede e sugere a do cabo. Confirme com Enter
(ou digite o nome certo, ex.: `enp3s0`, `thunderbolt0`, `enx...` para adaptador USB).

### Nos dois PCs — trocar chaves SSH

Feche o terminal, abra outro (para carregar o `.bashrc`) e rode:

```bash
bash ~/setup-ssh-keys.sh
```

Digite a senha do outro notebook uma única vez.

### Testar

```bash
bash ~/test-cluster.sh
```

Deve mostrar OK em ping, SSH, pasta compartilhada, velocidade do cabo, MPI e GPU.

### Rodar IA nos dois ao mesmo tempo

Sempre a partir do **node1**. O script Python precisa estar em `/srv/cluster`
(pasta compartilhada, visível nos dois):

```bash
cp ~/test-torch-distributed.py /srv/cluster/ && bash ~/run-ia.sh /srv/cluster/test-torch-distributed.py
```

Se aparecer `OK` de `node1` e de `node2`, os dois estão trabalhando juntos.
Para seus próprios scripts, use `torch.distributed` / `accelerate` e chame:

```bash
bash ~/run-ia.sh /srv/cluster/seu_script.py
```

## O que fica configurado

- Rede direta: node1 = `10.0.0.1`, node2 = `10.0.0.2` (via NetworkManager no Ubuntu Desktop, netplan no Server).
- `ssh node1` / `ssh node2` sem senha.
- `/srv/cluster` compartilhada por NFS (node1 é o servidor, monta sozinha no node2).
- `~/.cluster-env` com `NCCL_SOCKET_IFNAME`, `GLOO_SOCKET_IFNAME` e opções do OpenMPI apontando para o cabo.
- `~/ia-venv` com PyTorch, transformers, accelerate, mpi4py. Ative com `ia`.
- `~/cluster_hostfile` para `mpirun`.

## Problemas comuns

- **Ping falha**: confira se o cabo está na interface escolhida (`ip addr`). Cabo Ethernet direto funciona em placas modernas sem crossover.
- **SSH pede senha**: rode `bash ~/setup-ssh-keys.sh` nos DOIS lados; o usuário tem que ter o mesmo nome nos dois.
- **Sem GPU NVIDIA**: o teste usa CPU (backend gloo) e funciona igual, só mais devagar.
- **Refazer do zero**: `sudo bash cluster-ia-limpar.sh` e depois o setup de novo.
