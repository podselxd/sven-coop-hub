# Sven Coop Hub - canal de actualizaciones

Este repositorio solo contiene lo que los Hub descargan al actualizarse:

- `manifest.json`: version y SHA-256 de cada archivo.
- `manifest.sig`: firma RSA/SHA-256 del manifiesto. Cada Hub la verifica con la llave publica que lleva dentro; sin la firma valida no instala nada.
- `files/`: los scripts del Hub.

La llave privada de firma nunca se sube aqui.