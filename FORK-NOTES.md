# journeymap-webmap — fork pessoal

Fork de [TeamJM/journeymap-webmap](https://github.com/TeamJM/journeymap-webmap) (branch `26.3`,
base `d4cb6e1` / `26.3-1.0.13`) com um objetivo: **tirar os quadrados das chunks do mapa e
melhorar o HUD**.

## O que este repo é (e o que não é)

Este repo **não é o JourneyMap**. É o mod que provide o *webmap* — o servidor HTTP local
(Javalin) que serve o mapa num browser. Precisas dos dois.

O frontend (HTML/JS/CSS) vem num jar-in-jar, `META-INF/jars/webmap-client-1.2-SNAPSHOT.jar`,
e **não tem fonte neste repo**. Mas vem com source maps, por isso as fontes originais foram
recuperadas para `webmap-frontend/` (só para referência/leitura).

## Porquê um fork

A grelha das chunks no webmap é desenhada **no servidor**, dentro do PNG do tile
(`Tiles.java`, via a setting `showGrid` do JourneyMap). Como é o browser a mostrar o PNG,
**não há forma de a esconder só do lado do cliente** — precisa de suporte no servidor.
Daí a alteração em `Tiles.java` e o `?grid=` na URL do tile.

## Alterações

### 1. `?grid=` nos pedidos de tile — `common/.../routes/Tiles.java`

O `showGrid` deixa de vir só da setting do jogo e passa a aceitar um query param:

```
/tiles/tile.png?...&grid=0    → sem grelha
/tiles/tile.png?...&grid=1    → forca grelha
sem param                    → setting do JourneyMap, como antes
```

Aceita `0/1`, `true/false`, `yes/no`, `on/off`.

### 2. Toggle "Chunk grid" no HUD — `patch-webmap.ps1`

Adiciona um switch ao painel de settings ( grupo novo depois de Visibility), default
**desligado**. Liga-o ao `@change="setGridVisible($event)"`, que atualiza o estado e chama
`JM.resetTiles()` — sem isto nada acontece, porque o `JM` cacheia as URLs dos tiles por
slug e devolveria sempre a URL antiga.

### 3. Persistência das definições — `patch-webmap.ps1`

O upstream **perde tudo** a cada reload da página: visibility, follow mode, modo de mapa.
Agora vai para `localStorage` sob a chave `jm-webmap-settings`.

### 4. Botões de zoom — `patch-webmap.ps1`

O upstream só tinha a roda do rato. Num telemóvel ou num ecrã secundário isso é inútil.
Agora há `+`/`−` no canto superior esquerdo.

Usam **SVG inline** de propósito: em `index.js` só estão registados
`Settings/Box/Expand/Navigation/Earth/File/CircleX`, e o webpack fez tree-shake dos outros
ícones lucide para fora do bundle — `<lucide-icon-plus>` renderizava vazio.

## Como compilar

Requer **JDK 25** (o `gradle.properties` apontava para um path inexistente; já corrigido
para `C:/Program Files/Java/jdk-25`).

```powershell
.\gradlew.bat :fabric:build
```

## Como injectar o frontend

O jar compilado traz o frontend **original** dentro do jar-in-jar. O `WebMap.java` serve o
classpath copy apenas quando não há `assets_root`, e o caminho local que ele usa é apagado
a cada arranque — por isso editar ficheiros soltos não pega.

```powershell
powershell -ExecutionPolicy Bypass -File .\inject-frontend.ps1 `
    -BuiltJar .\fabric\build\libs\journeymap-webmap-fabric-1.0.13.jar
```

Isto reconstrói o jar-in-jar com `webmap-assets/` lá dentro e **verifica** que o resultado
contém os patches. Sai em `dist/`.

**Um jar só, zero configuração.**

## Instalar

1. Têm de estar os dois mods na pasta `mods` do perfil:
   - `journeymap-fabric-26.3-6.0.9.jar` (o JourneyMap)
   - o jar patcheado de `dist/`
2. Arrancar o jogo, abrir um mundo
3. O webmap serve em `http://localhost:8080` (ou a porta configurada)
4. O painel de settings fica no canto superior direito — aí está o "Chunk grid"

## Reconstruir o frontend depois de mexer nas fontes

As fontes legíveis estão em `webmap-frontend/src/main/js/`. Depois de as editar:

1. aplicá-las ao bundle minificado em `_official/webextract/assets/journeymap/web/bundled/bundle.js`
2. correr `.\patch-webmap.ps1` (refaz `webmap-assets/` a partir do bundle actualizado)
3. correr `inject-frontend.ps1`

Não há build de webpack disponível — o repo do frontend (`TeamJM/webmap-client`) é separado.
Os patches no bundle são substituições de string exactas e o script **aborta** se um anchor
não bater exactamente uma vez, por isso não falha em silêncio.