# Mi Band — obter a auth key (Huami)

A Mi Band moderna exige **server pairing**: primeiro pareia no app oficial, depois extrai a auth key (32 hex) para o lab Flutter.

**Não desparear** nem hard-reset da pulseira depois — invalida a key.

## 2. Ecossistema e apps oficiais

| App | Package | Backend | Uso típico MB6 |
|-----|---------|---------|----------------|
| **Zepp Life** (ex-Mi Fit) | `com.xiaomi.hm.health` | Zepp Health | **Preferido** para Mi Band ≤7 |
| Zepp (Amazfit) | `com.huami.watch.hmwatchmanager` | Zepp Health | Às vezes funciona mesmo sem suporte oficial |
| Mi Fitness / Xiaomi Wear | `com.xiaomi.wearable` | Xiaomi | Mais para séries novas (8+); logs às vezes têm key |

Fontes: [Gadgetbridge — Huami/Xiaomi server pairing](https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/), [Xiaomi gadgets — Mi Band](https://gadgetbridge.org/gadgets/wearables/xiaomi/#mi-band-6).

### Regras críticas (não quebrar a key)

- **Não desparear** a pulseira no app oficial → invalida a key.
- **Não hard-reset** a pulseira → muda MAC e invalida a key.
- Pode **desinstalar / tirar permissões** do app oficial depois de extrair a key (só não unpair).
- Enquanto testar o Flutter: Bluetooth do celular com Zepp Life **desligado / app morto**, senão disputa a conexão.

---

## 3. Como extrair a auth key (ordem prática)

### Método A — `huami-token` (sem root, via conta) ★ recomendado primeiro

Repo: [argrento/huami-token](https://github.com/argrento/huami-token)

1. Parear + sync MB6 no **Zepp Life** com conta e-mail/senha.
2. No PC:

```bash
# amazfit = login Zepp / Zepp Life (Huami)
huami-token --method amazfit --email SEU_EMAIL --password SUA_SENHA --bt_keys
```

3. Copiar o `Key` da Mi Band (32 hex). Guardar em local seguro (não commit).

Se a key não aparecer no backend Amazfit, tentar `--method xiaomi` **somente** se o pareamento foi via conta Xiaomi/Mi Fitness.

### Método B — Logs Mi Fitness (sem root, se usou esse app)

Path típico:

`/sdcard/Android/data/com.xiaomi.wearable/files/log/`

Arquivos: `XiaomiFit.device.log`, `XiaomiFit.main.log`, `Transfer.device.log`, backups `.bak`.

Campos: `authKey`, `encryptKey`, `token`, `huamiAuthKey` (versões novas às vezes deixam `authKey` null — usar `token`/`encryptKey`).

```bash
adb shell
grep -Eo '(encryptKey|token|authKey|huamiAuthKey)[":= ]+[[:xdigit:]]{32}' \
  /sdcard/Android/data/{com.xiaomi.wearable,com.mi.health}/files/log/*.log \
  | grep -oE '[[:xdigit:]]{32}' | sort | uniq
```

Usar a ocorrência **mais recente** (fim do arquivo).

### Método C — Root / sqlite

Zepp Life:

```bash
sqlite3 /data/data/com.xiaomi.hm.health/databases/origin_db_[NOME] \
  "select AUTHKEY from DEVICE"
```

Mi Fitness:

```bash
sqlite3 /data/data/com.xiaomi.wearable/databases/device_db \
  "select detail from device"
# JSON → auth_key
```

### Método D — Script no browser (Zepp / watchface.zepp.com)

Documentado no wiki Gadgetbridge: login em watchface maker + JS que chama API `users/{id}/devices` e lê `additionalInfo.auth_key`.

### Formato da key no nosso app

- Armazenar como 32 hex (ex.: `b0f9c10d025c6b7333bf21f3a701e5fc`)
- Em UIs estilo Gadgetbridge às vezes pedem prefixo `0x` — no código Flutter preferir bytes crus / hex sem `0x`
- **Nunca** commit em git; usar secure storage do dispositivo + `.env.local` / secrets ignorados

---
