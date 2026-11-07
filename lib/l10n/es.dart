/// Spanish UI strings, keyed by the English text in the code (see l10n.dart).
///
/// Neutral (Latin American) Spanish. TV labels are often narrow, so short
/// forms are used on purpose (ACT., PJ/G/P for standings, etc.). Keep every
/// `{placeholder}` exactly as in the key. `{s}` is an English-style plural
/// "s" filled in by the code; Spanish plurals don't always work that way
/// (canal/canales), so those strings are phrased to avoid it.
const Map<String, String> kEs = {
  // ── Startup / catalog sync ───────────────────────────────────────────
  'Starting...': "Iniciando…",
  'Content updated': "Contenido actualizado",
  'Startup failed:\n{bootstrapError}': "Error al iniciar:\n{bootstrapError}",
  'Retry': "Reintentar",
  'Your catalog has never been fully synced.':
      "Tu catálogo nunca se ha sincronizado por completo.",
  'Your catalog was last fully synced earlier today.':
      "Última sincronización completa del catálogo: hoy, más temprano.",
  'Your catalog was last fully synced {days} day{s} ago.':
      "Última sincronización completa del catálogo: hace {days} día{s}.",
  'Update content now?': "¿Actualizar el contenido ahora?",
  'This can take a few minutes on a large catalog. Skipping opens the app with what\'s already cached.':
      "Puede tardar unos minutos con un catálogo grande. Si lo omites, la app se abre con lo que ya está en caché.",
  'Skip for now': "Ahora no",
  'Update': "Actualizar",
  'Loading movies & TV shows...': "Cargando películas y series…",
  'Connecting to server...': "Conectando al servidor…",
  'Updating Content': "Actualizando contenido",
  '{done} / {total} categories': "{done} / {total} categorías",
  'This happens every few days to keep your catalog current — everyday launches open straight in.':
      "Esto ocurre cada pocos días para mantener tu catálogo al día; los demás días la app se abre directamente.",
  'Re-checks every visible category for new content. This can take a few minutes on a large catalog.':
      "Vuelve a revisar cada categoría visible en busca de contenido nuevo. Puede tardar unos minutos con un catálogo grande.",
  'Cancel': "Cancelar",

  // ── Multiview ────────────────────────────────────────────────────────
  'Multiview': "Multivista",
  'Layout': "Diseño",
  '2 channels': "2 canales",
  '4 channels': "4 canales",
  '= audio — click a channel to switch':
      "= audio — haz clic en un canal para cambiar",
  'Reload': "Recargar",
  'Change channel': "Cambiar de canal",
  'Remove': "Quitar",
  'Search channels...': "Buscar canales…",
  'Before you start': "Antes de empezar",
  'Every screen in Multiview is its own connection to your provider. Your playlist must allow at least as many connections as screens you open (see Max connections in Playlist Manager).\n\nIf two screens share an account that allows only one connection, they keep kicking each other off and will freeze or buffer. Tip: use channels from different playlists, one per account.\n\nA screen that freezes restarts on its own. If it doesn\'t, hold Select on it and choose Reload.':
      "Cada pantalla de la Multivista es una conexión propia con tu proveedor. Tu lista debe permitir al menos tantas conexiones como pantallas abras (ver Conexiones máx. en Gestor de listas).\n\nSi dos pantallas comparten una cuenta que solo permite una conexión, se desconectan entre sí y se congelan o cargan sin parar. Consejo: usa canales de listas distintas, una por cuenta.\n\nUna pantalla congelada se reinicia sola. Si no, mantén OK sobre ella y elige Recargar.",
  'Don\'t show this again': "No volver a mostrar",
  'OK': "OK",
  'Couldn\'t start that channel': "No se pudo iniciar ese canal",
  'Full screen': "Pantalla completa",
  'Windowed': "En ventana",
  '4 screens': "4 pantallas",
  '2 screens': "2 pantallas",
  '= audio — Select to switch, hold Select for options':
      "= audio — OK para cambiar, mantén OK para opciones",
  'Pick a channel': "Elige un canal",
  'No channels found': "No se encontraron canales",
  'Open in Multiview': "Abrir en Multivista",

  // ── Player ───────────────────────────────────────────────────────────
  'Recall — recently watched': "Recientes — vistos hace poco",
  'No other live channels watched yet this session.':
      "Todavía no has visto otros canales en vivo en esta sesión.",
  'Recall — go back to a recent channel':
      "Recientes — volver a un canal reciente",
  'Remove from favorites': "Quitar de favoritos",
  'Add to favorites': "Añadir a favoritos",
  'Reload channel': "Recargar canal",
  'Previous episode': "Episodio anterior",
  'Next episode': "Episodio siguiente",
  'Ending now': "Terminando",
  '{minutes} min left': "Quedan {minutes} min",
  'Back': "Atrás",
  'Fit to screen': "Ajustar a la pantalla",
  'Fill screen': "Llenar la pantalla",
  'Closed captions (CC) — if the channel broadcasts them': "Subtítulos (CC) — si el canal los emite",
  'Up Next': "A continuación",
  'Playing in {countdown}s': "Reproduciendo en {countdown} s",
  'Playing now...': "Reproduciendo…",
  'Play now': "Reproducir ya",
  'Dismiss': "Descartar",
  'Select a channel to start watching': "Elige un canal para empezar a ver",
  'Switch to {p}: {name}': "Cambiar a {p}: {name}",
  'Switch to {playlistName}: {name}': "Cambiar a {playlistName}: {name}",
  'Technical details': "Detalles técnicos",
  'This device\'s video decoder couldn\'t play this stream — likely 4K HDR (HEVC 10-bit). If your provider offers an HD (non-4K) version of this channel or title, try that. If another app plays this stream on this device, please report it with a photo of the technical details below.':
      "El decodificador de video de este dispositivo no pudo reproducir esta transmisión; probablemente sea 4K HDR (HEVC 10 bits). Si tu proveedor ofrece una versión HD (no 4K) de este canal o título, prueba con esa. Si otra app reproduce esta transmisión en este dispositivo, avísanos con una foto de los detalles técnicos de abajo.",
  'Playback error:\n{raw}': "Error de reproducción:\n{raw}",
  'Subtitles': "Subtítulos",
  'Off': "Desactivados",
  'Forced': "Forzados",
  'Online':
      'En línea',
  'Search online subtitles':
      'Buscar subtítulos en línea',
  'From your add-ons (Settings > Add-ons)':
      'Con tus complementos (Ajustes > Complementos)',
  'Online subtitles':
      'Subtítulos en línea',
  'No subtitles found for this title.':
      'No se encontraron subtítulos para este título.',
  "Couldn't download that subtitle. Try another.":
      'No se pudo descargar ese subtítulo. Prueba otro.',
  'Add-ons':
      'Complementos',
  'Online subtitles in more languages':
      'Subtítulos en línea en más idiomas',
  'Remove {name}?':
      '¿Quitar {name}?',
  "That link isn't a subtitle add-on (only subtitle add-ons are supported).":
      'Ese enlace no es un complemento de subtítulos (solo se admiten esos).',
  'That add-on is already in the list.':
      'Ese complemento ya está en la lista.',
  '{name} added.':
      '{name} añadido.',
  "Add-ons find subtitles online for movies and episodes, in many languages. They are free community services, separate from your provider — iptv-app only uses them for subtitles. Turn one on, then pick \"Search online subtitles\" in the player's Subtitles button.":
      'Los complementos buscan subtítulos en línea para películas y episodios, en muchos idiomas. Son servicios comunitarios gratuitos, distintos de tu proveedor — iptv-app solo los usa para subtítulos. Activa uno y elige «Buscar subtítulos en línea» en el botón Subtítulos del reproductor.',
  'Subtitle add-ons':
      'Complementos de subtítulos',
  'Subtitles in 60+ languages from OpenSubtitles.org':
      'Subtítulos en más de 60 idiomas de OpenSubtitles.org',
  'Hold OK to remove':
      'Mantén OK para quitar',
  'Add an add-on':
      'Añadir un complemento',
  'Add-on link (ends with manifest.json)':
      'Enlace del complemento (termina en manifest.json)',
  'Only subtitle add-ons work here. When one is on, the title and episode you are watching are sent to it to find subtitles; nothing else is shared.':
      'Aquí solo funcionan complementos de subtítulos. Cuando uno está activo, se le envían el título y el episodio que ves para buscar subtítulos; no se comparte nada más.',
  'Looking for {language} subtitles…':
      "Buscando subtítulos en {language}…",
  'No {language} subtitles online for this title.':
      "No hay subtítulos en {language} en línea para este título.",
  'Track {id}': "Pista {id}",
  'Audio Track': "Pista de audio",
  'Audio track': "Pista de audio",

  // ── Catalog / browse ─────────────────────────────────────────────────
  'Sort': "Ordenar",
  'Default': "Predeterminado",
  'A to Z': "A a Z",
  'Z to A': "Z a A",
  'Rating (high to low)': "Calificación (mayor a menor)",
  'Date added/updated': "Fecha de alta/act.",
  'Fetching TMDB release dates... {done}/{total}':
      "Obteniendo fechas de estreno de TMDB… {done}/{total}",
  'Added to Favorites': "Añadido a favoritos",
  'Removed from Favorites': "Quitado de favoritos",
  'No items in this group.': "No hay nada en este grupo.",
  'Re-checks your M3U playlist URL(s) for new content.':
      "Vuelve a revisar la URL de tus listas M3U en busca de contenido nuevo.",
  'Set your playlist source in Settings first.':
      "Primero configura tu lista en Ajustes.",
  'Continue Watching': "Seguir viendo",
  'Search': "Buscar",
  'Update content': "Act. contenido",
  'Update EPG now': "Act. guía",
  'Settings': "Ajustes",
  'No TV shows found. Pick a category on the left.':
      "No se encontraron series. Elige una categoría a la izquierda.",
  'No channels found.': "No se encontraron canales.",
  'Loading playlist...': "Cargando lista…",
  'Failed to load playlist.': "No se pudo cargar la lista.",
  'Open Settings': "Abrir Ajustes",
  '{p}% watched': "{p} % visto",
  'Resume': "Reanudar",
  'Play': "Reproducir",
  'Restart': "Desde el inicio",
  'Failed to load episodes.': "No se pudieron cargar los episodios.",
  'No episodes found.': "No se encontraron episodios.",
  'Season {season}': "Temporada {season}",
  'Expand catalog': "Catálogo completo",
  'Browse': "Explorar",
  'Playlist': "Lista",
  'Previous': "Anterior",
  'Next': "Siguiente",
  'Loading...': "Cargando…",
  'Loading…': "Cargando…",
  'No recently added movies yet': "Aún no hay películas añadidas recientemente",
  'Loading movie categories...': "Cargando categorías de películas…",
  'No recently added shows yet': "Aún no hay series añadidas recientemente",
  'Loading TV show categories...': "Cargando categorías de series…",
  "What's New": "Novedades",

  // ── Search ───────────────────────────────────────────────────────────
  'Switch Profile': "Cambiar de perfil",
  'Restricted': "Restringido",
  'Search everything...': "Buscar en todo…",
  'Search everything... (press OK to type)': "Buscar en todo… (OK para escribir)",
  'Still loading the full catalog in the background ({warmCatalogDone}/{warmCatalogTotal} categories) — some results may not show up yet.':
      "El catálogo completo aún se está cargando en segundo plano ({warmCatalogDone}/{warmCatalogTotal} categorías); puede que falten algunos resultados.",
  'Search Live TV, Movies & TV Shows':
      "Busca en TV en vivo, películas y series",
  'Recent searches': "Búsquedas recientes",
  'Clear': "Borrar",
  'Live TV': "TV en vivo",
  'Movies': "Películas",
  'TV Shows': "Series",
  'Nothing found': "Sin resultados",

  // ── Sports ───────────────────────────────────────────────────────────
  'Sports': "Deportes",
  'this team': "este equipo",
  'My Teams': "Mis equipos",
  'Last channels': "Últimos canales",
  '◀ ▶ tabs  ·  OK to watch  ·  Back to close':
      "◀ ▶ pestañas  ·  OK para ver  ·  Atrás para cerrar",
  'None of your teams play today.': "Ninguno de tus equipos juega hoy.",
  'Follow teams from {tab} > Standings to see them here.':
      "Sigue equipos desde {tab} > Clasificación para verlos aquí.",
  'No games from your leagues are live right now.':
      "Ningún partido de tus ligas está en directo ahora.",
  'Hold OK on a team to unfollow · on a game to pick the channel':
      "Mantén OK en un equipo para dejar de seguirlo · en un partido para elegir el canal",
  'Add team': "Añadir equipo",
  'Follow one from Standings': "Sigue uno desde la tabla",
  'Could not load': "No se pudo cargar",
  'Follow your teams to see them here': "Sigue a tus equipos para verlos aquí",
  'Follow another team': "Seguir otro equipo",
  'Add team opens Standings: hold OK on a team to follow it.':
      "«Añadir equipo» abre la tabla: mantén OK en un equipo para seguirlo.",
  'This team could not be loaded. Check the connection.':
      "No se pudo cargar este equipo. Revisa la conexión.",
  'Next 2 weeks': "Próximas 2 semanas",
  'No games in the next two weeks.':
      "No hay partidos en las próximas dos semanas.",
  'vs': "vs",
  'at': "@",
  'Today {time}': "Hoy {time}",
  'Tomorrow {time}': "Mañana {time}",
  'Last game: {opponent} · Final': "Últ. partido: {opponent} · Final",
  'Last game: {result} {mine}-{other} {opponent}':
      "Últ. partido: {result} {mine}-{other} {opponent}",
  'LIVE': "EN VIVO",
  'Looking…': "Buscando…",
  'TEAM': "EQUIPO",
  'Later today': "Hoy, más tarde",
  'Tomorrow': "Mañana",
  'Not played': "No jugados",
  'Scheduled': "Programados",
  'Live now': "En vivo",
  'Final': "Final",
  'All': "Todo",
  'Edit leagues': "Ligas",
  'Scores hidden': "Marcadores ocultos",
  'Scores shown': "Marcadores visibles",
  'Yesterday': "Ayer",
  'Today': "Hoy",
  'Standings': "Clasificación",
  '{name} standings': "Clasificación {name}",
  '{name} championship': "Campeonato de {name}",
  'No games on this day for your leagues':
      "No hay partidos este día en tus ligas",
  'Try another day, or add leagues with Edit leagues.':
      "Prueba otro día o añade ligas con el botón Ligas.",
  'Live now  {count}': "En vivo  {count}",
  'Live': "En vivo",
  'Starts in {p}{p2}m': "Empieza en {p}{p2} min",
  'Looking for the channel…': "Buscando el canal…",
  'No channel found — OK to pick one':
      "No se encontró canal — OK para elegir uno",
  'Hold OK to pick or swap the channel':
      "Mantén OK para elegir o cambiar el canal",
  'Hold OK: pick the channel  ·  ▶❚❚: watch here':
      "Mantén OK: elegir el canal  ·  ▶❚❚: ver aquí",
  'Tap the game again: full screen  ·  Back: stop':
      "Toca el partido otra vez: pantalla completa  ·  Atrás: detener",
  'Tap: watch here  ·  Hold: pick the channel':
      "Tocar: ver aquí  ·  Mantener: elegir el canal",
  'Play here': "Reproducir aquí",
  '{channel} · plays at the top of {tab}':
      "{channel} · se reproduce arriba en {tab}",
  '▶❚❚: watch this game  ·  Back: playing game':
      "▶❚❚: ver este partido  ·  Atrás: partido en curso",
  'OK: full screen  ·  ▶❚❚ or Back: stop':
      "OK: pantalla completa  ·  ▶❚❚ o Atrás: detener",
  'Still looking for channels…': "Todavía buscando canales…",
  'No channel found for this game': "No se encontró canal para este partido",
  'On {matches} channel{s}': "Canales: {matches}",
  'Pick the channel': "Elegir el canal",
  'Choose a different channel': "Elegir otro canal",
  'Search your channels — it can be remembered for this game or team':
      "Busca en tus canales; se puede recordar para este partido o equipo",
  'Forget my pick': "Olvidar mi elección",
  'Go back to the automatic match': "Volver a la elección automática",
  'Remember this channel?': "¿Recordar este canal?",
  'Just this game': "Solo este partido",
  'Best for channels named after one game':
      "Ideal para canales con el nombre de un partido",
  'Always for the {shortName}': "Siempre para {shortName}",
  'Best for a regular channel, like a regional network':
      "Ideal para un canal fijo, como una cadena regional",
  'Leagues': "Ligas",
  'Save': "Guardar",
  'Pick the channel for {title}': "Elige el canal para {title}",
  'Search channels': "Buscar canales",
  'No channels match "{query}"': "Ningún canal coincide con «{query}»",
  '{results}{p} channels': "{results}{p} canales",
  '{group} · Now: {now}': "{group} · Ahora: {now}",
  'Preseason': "Pretemporada",
  'Pick a league above, then hold OK on a team to follow it. Back returns to My Teams.':
      "Elige una liga arriba y mantén OK en un equipo para seguirlo. Atrás vuelve a Mis equipos.",
  'Standings could not be loaded. Check the connection.':
      "No se pudo cargar la clasificación. Revisa la conexión.",
  'switch conference': "cambiar conferencia",
  'switch table': "cambiar de tabla",
  'Hold OK on a team to follow it (My Teams)':
      "Mantén OK en un equipo para seguirlo (Mis equipos)",
  'Your pick': "Tu elección",
  'Found by its name': "Encontrado por su nombre",
  'Found in the guide': "Encontrado en la guía",
  'National broadcast': "Transmisión nacional",
  'Some scores could not be loaded. Check the connection.':
      "No se pudieron cargar algunos marcadores. Revisa la conexión.",
  'Unfollow': "Dejar de seguir",
  'Follow': "Seguir",
  'Remove from My Teams': "Quitar de Mis equipos",
  'Add to My Teams — their games show first in {tab}':
      "Añadir a Mis equipos: sus partidos salen primero en {tab}",
  // Results (W/L/D = won/lost/draw) and standings columns.
  'W': "G",
  'L': "P",
  'D': "E",
  'T': "E",
  'GP': "PJ",
  'GD': "DIF",
  'PTS': "PTS",
  'OTL': "PPR",
  'DIFF': "DIF",
  'STRK': "RACHA",
  'L10': "ÚLT10",
  'REC': "G-P",
  'PF': "PF",
  'PA': "PC",
  'HOME': "LOCAL",
  'AWAY': "VISIT",
  'PCT': "PCT",
  'GB': "JD",

  // ── TV home ──────────────────────────────────────────────────────────
  'TV': "TV",
  'Favorites': "Favoritos",
  'Favourites': "Favoritos",
  'Remove from Favourites': "Quitar de favoritos",
  'Add to Favourites': "Añadir a favoritos",
  'Cancel Hide': "Cancelar ocultar",
  'Hide Group': "Ocultar grupo",
  'Move Up / Down': "Subir / bajar",
  'Move to Top': "Mover arriba del todo",
  'Unhide this channel': "Volver a mostrar este canal",
  'Hide this channel': "Ocultar este canal",
  'Double': "Doble",
  'for groups': "para los grupos",
  'Exit and free up this login?': "¿Salir y liberar esta cuenta?",
  'This disconnects your login here so it can be used on another device, then fully closes iptv-app. Your channels/movies will need to reload next time you open it.':
      "Esto desconecta tu cuenta aquí para que se pueda usar en otro dispositivo y luego cierra iptv-app por completo. Tus canales y películas tendrán que volver a cargarse la próxima vez.",
  'Exit': "Salir",
  'Exit {appName}?': "¿Salir de {appName}?",
  'Are you sure you want to exit {appName}?':
      "¿Seguro que quieres salir de {appName}?",
  'Stay': "Quedarme",
  'History': "Historial",
  'No channels watched yet.': "Todavía no has visto ningún canal.",
  'Update Content': "Act. contenido",
  'Minimize': "Minimizar",
  'Close': "Cerrar",
  'Disable and exit': "Desactivar y salir",
  'Long-press a group elsewhere to favorite the whole thing.':
      "Mantén OK en un grupo en otra parte para añadirlo entero a favoritos.",
  'Nothing playing': "Nada en reproducción",
  'Click to resume': "Clic para reanudar",
  'Filter channels in this group...': "Filtrar canales de este grupo…",
  'Close filter': "Cerrar filtro",
  'Hidden — find it again in Settings > Playlist Manager > Hidden Channels':
      "Oculto: lo encontrarás en Ajustes > Gestor de listas > Canales ocultos",
  'Unhidden': "Visible otra vez",
  'No favorited movies or TV shows yet.\nHold Select on a poster to add one.':
      "Aún no hay películas ni series en favoritos.\nMantén OK en un póster para añadir una.",
  'No favorited movies yet.': "Aún no hay películas en favoritos.",
  'No favorited TV shows yet.': "Aún no hay series en favoritos.",
  'No favorite channels yet — press Down while watching one to add it.':
      "Aún no hay canales favoritos: pulsa Abajo mientras ves uno para añadirlo.",
  'Updating…': "Actualizando…",
  'No program data': "Sin programación",
  'No program data available': "Programación no disponible",
  'Next: {title} ({p})': "Después: {title} ({p})",
  'Focus a program to see details':
      "Selecciona un programa para ver los detalles",
  'Space': "Espacio",
  'Loading EPG…': "Cargando guía…",

  // ── Welcome ──────────────────────────────────────────────────────────
  'Hey beautiful Human,': "Hola, hermoso humano,",
  'Hey beautiful Human': "Hola, hermoso humano",
  'Welcome to iptv-app': "Bienvenido a iptv-app",
  'Add your first playlist?': "¿Añadir tu primera lista?",
  'Add a playlist to kick things off, or skip for now if you just want to browse and discover the app without content.':
      "Añade una lista para empezar, u omítelo por ahora si solo quieres recorrer y descubrir la app sin contenido.",

  // ── Add playlist ─────────────────────────────────────────────────────
  'Add Playlist': "Añadir lista",
  'Paste some text first.': "Primero pega algún texto.",
  "Couldn't find anything usable in that text.":
      "No se encontró nada útil en ese texto.",
  'Received from your phone — check the details, then press Add Playlist.':
      "Recibido desde tu teléfono: revisa los datos y pulsa «Añadir lista».",
  'Scan the code with your phone and send the form first.':
      "Primero escanea el código con tu teléfono y envía el formulario.",
  'Playlist name is required.': "El nombre de la lista es obligatorio.",
  'Server, username, and password are all required.':
      "Servidor, usuario y contraseña son obligatorios.",
  'M3U playlist URL is required.': "La URL de la lista M3U es obligatoria.",
  'Playlist updated.': "Lista actualizada.",
  'Playlist added.': "Lista añadida.",
  'Download content': "Descargar contenido",
  'This provider has a large catalog. Download everything in the background, or choose which groups to include first?':
      "Este proveedor tiene un catálogo grande. ¿Descargar todo en segundo plano o elegir primero qué grupos incluir?",
  'Choose Groups First': "Elegir grupos",
  'Download All': "Descargar todo",
  'Edit Playlist': "Editar lista",
  'Playlist source': "Origen de la lista",
  'M3U URL': "URL M3U",
  'Xtream Codes': "Xtream Codes",
  'Smart Add': "Añadido inteligente",
  'From phone': "Desde el teléfono",
  'Playlist name': "Nombre de la lista",
  'Name': "Nombre",
  'e.g. My Provider': "p. ej. Mi proveedor",
  'M3U Playlist URL': "URL de la lista M3U",
  'EPG (XMLTV) URL': "URL de la guía (XMLTV)",
  'Paste the message your provider sent you — we\'ll pull out the server, username, and password.':
      "Pega el mensaje que te envió tu proveedor; sacaremos el servidor, el usuario y la contraseña.",
  'Paste provider message': "Pegar mensaje del proveedor",
  'Parse': "Analizar",
  'Confirm the server': "Confirmar el servidor",
  'No server URL found in that text — enter it below.':
      "No hay URL de servidor en ese texto; escríbela abajo.",
  'Server URL (e.g. http://host:port)':
      "URL del servidor (p. ej. http://host:puerto)",
  'Username': "Usuario",
  'Password': "Contraseña",
  'Custom EPG (XMLTV) URL — optional': "URL de guía propia (XMLTV) — opcional",
  'Leave blank to use the panel\'s own xmltv.php. Set this if your provider\'s EPG is empty or unreliable (e.g. a third-party feed like EPGgenius) — it only fills in a channel if that feed\'s ids match this panel\'s.':
      "Déjalo vacío para usar el xmltv.php del panel. Rellénalo si la guía de tu proveedor está vacía o no es fiable (p. ej. una fuente externa como EPGgenius); solo completa un canal si los ID de esa fuente coinciden con los del panel.",
  'Paste different text': "Pegar otro texto",
  'Status': "Estado",
  'Failed to add playlist: {p}': "No se pudo añadir la lista: {p}",
  'Save Changes': "Guardar cambios",
  'Fill in the form on the left, then press {p} above.':
      "Rellena el formulario de la izquierda y pulsa «{p}» arriba.",
  'Unexpected Xtream API response': "Respuesta inesperada de la API Xtream",
  'Invalid Xtream username/password':
      "Usuario o contraseña de Xtream no válidos",
  'Xtream account is not active (status: {status})':
      "La cuenta Xtream no está activa (estado: {status})",

  // ── Phone pairing ────────────────────────────────────────────────────
  'Code expired': "Código caducado",
  'Add from your phone': "Añadir desde tu teléfono",
  'Typing a long password with a remote is painful. Scan this code with your phone camera and fill in the form there — it appears here for you to check and add.':
      "Escribir una contraseña larga con el control remoto es un fastidio. Escanea este código con la cámara del teléfono y rellena el formulario allí; aparecerá aquí para que lo revises y lo añadas.",
  'Scan with your phone (mobile data is fine).':
      "Escanea con tu teléfono (los datos móviles sirven).",
  'Connect your phone to the same Wi-Fi as this TV, then scan.':
      "Conecta tu teléfono al mismo Wi-Fi que esta TV y luego escanea.",
  'Fill in the form and tap Send to TV.':
      "Rellena el formulario y toca «Send to TV».",
  'Check the details here, then press Add Playlist.':
      "Revisa los datos aquí y pulsa «Añadir lista».",
  'Waiting for your phone…': "Esperando a tu teléfono…",
  'Or open on the phone:': "O abre en el teléfono:",
  'Your details are encrypted on the phone; the relay only passes along scrambled data and deletes it.':
      "Tus datos se cifran en el teléfono; el relé solo transmite datos cifrados y luego los borra.",
  'New code': "Nuevo código",
  'Phone on this Wi-Fi? Use the Wi-Fi code':
      "¿Teléfono en este Wi-Fi? Usa el código Wi-Fi",
  'Phone not on this Wi-Fi? Use the other code':
      "¿Teléfono fuera de este Wi-Fi? Usa el otro código",

  // ── Channel linking / EPG matching ───────────────────────────────────
  'Add and enable a second playlist first — a link connects a channel on one playlist to its equivalent on another.':
      "Primero añade y activa una segunda lista: un enlace une un canal de una lista con su equivalente en otra.",
  'Auto-Pair Channels': "Emparejar auto.",
  'Unpair Channels': "Desemparejar",
  'Reviewing {reviewFilter} auto-paired channel{s} — type to search all instead':
      "Revisando canales emparejados auto. ({reviewFilter}): escribe para buscar en todos",
  'Search your channels': "Buscar en tus canales",
  'Not linked': "Sin enlazar",
  'Linked channel no longer available':
      "El canal enlazado ya no está disponible",
  'Linked to {p}: {name}': "Enlazado a {p}: {name}",
  'Clear link': "Quitar enlace",
  'Link "{name}"': "Enlazar «{name}»",
  'Search other playlists\' channels': "Buscar en los canales de otras listas",
  'No matches.': "Sin coincidencias.",
  'No EPG feed has been loaded yet this session — run "Update EPG Now" first so there\'s a channel directory to match against.':
      "Aún no se cargó ninguna guía en esta sesión: ejecuta primero «Act. guía» para tener un directorio de canales.",
  'No EPG feed has been loaded yet this session — run "Update EPG Now" above first so there\'s a channel directory to search.':
      "Aún no se cargó ninguna guía en esta sesión: ejecuta primero «Act. guía» (arriba) para tener un directorio de canales.",
  'Assigned: {p}': "Asignado: {p}",
  'Matched automatically': "Asociado automáticamente",
  'Clear assignment': "Quitar asignación",
  'Assign "{channelName}"': "Asignar «{channelName}»",
  'Search the EPG feed\'s channels': "Buscar en los canales de la guía",
  'No EPG feed has been loaded yet this app session — go back and run "Update EPG Now" first.':
      "Aún no se cargó ninguna guía en esta sesión: vuelve atrás y ejecuta primero «Act. guía».",
  'Now: {title}': "Ahora: {title}",
  'No current program data': "Sin programa actual",
  'Channels are pairing, please wait…': "Emparejando canales, espera…",
  'No new matches found — anything still unmatched needs a manual pick.':
      "No hay nuevas coincidencias; lo que falte hay que elegirlo a mano.",
  'Paired {paired} channel{s} automatically.':
      "Canales emparejados automáticamente: {paired}.",
  'Review': "Revisar",
  'Continue': "Continuar",
  'Nothing was auto-paired — there\'s nothing to undo.':
      "No se emparejó nada automáticamente; no hay nada que deshacer.",
  'Undo {autoPairedCount} automatic pairing{s}? Anything you\'ve set by hand is kept.':
      "¿Deshacer los emparejamientos automáticos ({autoPairedCount})? Lo que hiciste a mano se conserva.",
  'Unpair': "Desemparejar",

  // ── Check for updates ────────────────────────────────────────────────
  'Couldn\'t open the download link.':
      "No se pudo abrir el enlace de descarga.",
  'Allow installing updates': "Permitir instalar actualizaciones",
  'Android needs one-time permission for iptv-app to install an update it downloaded. The next screen is Android\'s own settings — turn the toggle on, then come back here and press Install again.':
      "Android necesita un permiso único para que iptv-app instale una actualización descargada. La siguiente pantalla es de los ajustes de Android: activa la opción, vuelve aquí y pulsa Instalar otra vez.",
  'Check for Updates': "Buscar actualizaciones",
  'Current version: —': "Versión actual: —",
  'Current version: {currentVersion}': "Versión actual: {currentVersion}",
  'Checking...': "Comprobando…",
  'You\'re on the latest version.': "Tienes la última versión.",
  'Check Again': "Volver a comprobar",
  'Version {version} is available': "La versión {version} está disponible",
  'Open Download Page': "Abrir página de descarga",
  'Opens in your browser — unzip the download and run the application to update, replacing the old folder.':
      "Se abre en tu navegador: descomprime la descarga y ejecuta the application para actualizar, reemplazando la carpeta anterior.",
  'Download & Install': "Descargar e instalar",
  'Downloading update... {p}%': "Descargando actualización… {p} %",
  'Download complete.': "Descarga completa.",
  'Install': "Instalar",
  'Android will ask you to confirm the install — that\'s normal, not every app can skip it.':
      "Android te pedirá que confirmes la instalación; es normal, no todas las apps pueden saltarse ese paso.",
  'Something went wrong: {p}': "Algo salió mal: {p}",
  'unknown error': "error desconocido",
  'Try Again': "Reintentar",
  'GitHub is temporarily rate-limiting update checks from this network — try again in about {n} minute.':
      "GitHub está limitando temporalmente las comprobaciones desde esta red; vuelve a intentarlo en {n} minuto aprox.",
  'GitHub is temporarily rate-limiting update checks from this network — try again in about {n} minutes.':
      "GitHub está limitando temporalmente las comprobaciones desde esta red; vuelve a intentarlo en {n} minutos aprox.",
  'GitHub is temporarily rate-limiting update checks from this network — try again shortly.':
      "GitHub está limitando temporalmente las comprobaciones desde esta red; vuelve a intentarlo en un rato.",

  // ── EPG settings ─────────────────────────────────────────────────────
  'No EPG URL set yet — add a playlist first.':
      "Todavía no hay URL de guía; primero añade una lista.",
  'Cache cleared.': "Caché borrada.",
  'EPG': "Guía (EPG)",
  'General': "General",
  'EPG Matching': "Asoc. de guía",
  'Channel Pairing': "Emparejar canales",
  'Auto-refresh interval': "Intervalo de act. automática",
  '{p} hours': "{p} horas",
  'EPG never updated': "La guía nunca se actualizó",
  'EPG last updated: {p}': "Última act. de la guía: {p}",
  'Update EPG Now': "Act. guía",
  'Clear Cache': "Borrar caché",
  'Clears the cached EPG and catalog data — playlist source, favorites, and group visibility are kept.':
      "Borra la guía y el catálogo en caché; se conservan el origen de las listas, los favoritos y la visibilidad de los grupos.",
  'Fixes a channel with no program data by manually assigning it to an entry in the loaded EPG feed — useful when a provider\'s own id doesn\'t match a third-party source.':
      "Arregla un canal sin programación asignándolo a mano a una entrada de la guía cargada; útil cuando el ID del proveedor no coincide con una fuente externa.",
  'Links a channel on one playlist to its equivalent on another. If a live channel fails to load, or you switch to it yourself from the player, playback can fall back to the paired channel on the other playlist instead.':
      "Une un canal de una lista con su equivalente en otra. Si un canal en vivo no carga, o cambias tú desde el reproductor, la reproducción puede pasar al canal emparejado de la otra lista.",

  // ── General settings ─────────────────────────────────────────────────
  'Clear search & channel history?':
      "¿Borrar el historial de búsqueda y canales?",
  'Removes your recent searches and the History list of live channels.':
      "Elimina tus búsquedas recientes y el historial de canales en vivo.",
  'Search and channel history cleared.':
      "Historial de búsqueda y canales borrado.",
  'Clear Movies & TV Shows history?':
      "¿Borrar el historial de películas y series?",
  'Removes Continue Watching and the saved progress of every movie and episode.':
      "Elimina Seguir viendo y el progreso guardado de cada película y episodio.",
  'Movies & TV Shows history cleared.':
      "Historial de películas y series borrado.",
  'Language': "Idioma",
  'Follows the device language': "Usa el idioma del dispositivo",
  'Automatic': "Automático",
  'Startup': "Inicio",
  'Resume last channel in full screen':
      "Reanudar el último canal en pantalla completa",
  'Opens the last live channel full screen after the splash.':
      "Abre el último canal en vivo en pantalla completa tras la pantalla de inicio.",
  'Resume last channel with the guide open':
      "Reanudar el último canal con la guía abierta",
  'Plays the last live channel in the small preview, with the channel list.':
      "Reproduce el último canal en vivo en la vista previa pequeña, con la lista de canales.",
  'Both off: nothing plays at startup (a "Hold > to resume" reminder instead).':
      "Ambos desactivados: no se reproduce nada al iniciar (un aviso «Mantén > para reanudar» en su lugar).",
  'Tabs': "Pestañas",
  'Hide Movies and TV Shows': "Ocultar Películas y Series",
  'Removes both tabs and their search results, e.g. if you watch movies and shows elsewhere.':
      "Quita ambas pestañas y sus resultados de búsqueda, p. ej. si ves películas y series en otro lugar.",
  'Favorite channels are in the TV tab, under Favourites.':
      "Los canales favoritos están en la pestaña TV, en Favoritos.",
  'Show the Multiview tip': "Mostrar el consejo de Multivista",
  'The connections reminder shown when opening Multiview.':
      "El aviso sobre conexiones al abrir la Multivista.",
  'Resume reminder': "Aviso para reanudar",
  'Show the "Hold > to resume" reminder':
      "Mostrar el aviso «Mantén > para reanudar»",
  'The pill at the bottom while a channel plays in the background. Off: hidden.':
      "La píldora de abajo mientras un canal suena en segundo plano. Desactivado: oculta.",
  'The pill at the bottom while a channel plays in the background. Off: hidden — holding Right still resumes.':
      "La píldora de abajo mientras un canal suena en segundo plano. Desactivado: oculta; mantener Derecha sigue reanudando.",
  'Clear search & channel history': "Borrar historial de búsqueda y canales",
  'Recent searches and the live channel History':
      "Búsquedas recientes e historial de canales en vivo",
  'Clear Movies & TV Shows history': "Borrar historial de películas y series",
  'Continue Watching and saved progress': "«Seguir viendo» y progreso guardado",

  // ── Group management / hidden channels ───────────────────────────────
  'Leave group selection?': "¿Salir de la selección de grupos?",
  'Your show/hide choices are saved, and anything still visible will start downloading — same as pressing Done.':
      "Tus elecciones de mostrar/ocultar se guardan y todo lo visible empezará a descargarse, igual que al pulsar Listo.",
  'Leave': "Salir",
  'Save playlist?': "¿Guardar la lista?",
  'Your playlist will be saved with the selected groups. You can always add or remove groups later in Settings > Group Management.':
      "Tu lista se guardará con los grupos elegidos. Siempre puedes añadir o quitar grupos después en Ajustes > Gestión de grupos.",
  'Confirm': "Confirmar",
  'Group Management': "Gestión de grupos",
  'Done': "Listo",
  'If you are done selecting your groups, press Confirm below.\n\nIf you are not done yet, press Left to go back to your categories.':
      "Si terminaste de elegir tus grupos, pulsa Confirmar abajo.\n\nSi aún no, pulsa Izquierda para volver a tus categorías.",
  'No categories yet — load a playlist first.':
      "Aún no hay categorías; primero carga una lista.",
  'Show All': "Mostrar todo",
  'Hide All': "Ocultar todo",
  'Hidden channels': "Canales ocultos",
  'No channels are individually hidden. Hide one from its row in the Live TV list.':
      "No hay canales ocultos individualmente. Oculta uno desde su fila en la lista de TV en vivo.",
  'Unhide': "Mostrar",
  'Show group': "Mostrar grupo",
  'Hide group': "Ocultar grupo",

  // ── Playlist manager / priority ──────────────────────────────────────
  'Playlist Manager': "Gestor de listas",
  'Playlist Priority': "Prioridad de listas",
  'Which playlist\'s groups show first, per tab':
      "Qué lista muestra sus grupos primero, por pestaña",
  'No playlists yet — tap "Add Playlist" above to get started.':
      "Aún no hay listas: pulsa «Añadir lista» arriba para empezar.",
  'Delete playlist?': "¿Eliminar la lista?",
  'This removes "{name}"\'s login and cached catalog from this device. Its favorited channels/movies stay in your shared Favorites list, but will no longer play unless you add this playlist back.':
      "Esto elimina de este dispositivo la cuenta y el catálogo en caché de «{name}». Sus canales y películas favoritos siguen en tus Favoritos, pero no se reproducirán hasta que vuelvas a añadir esta lista.",
  'Delete': "Eliminar",
  'Add backup server': "Añadir servidor de respaldo",
  'The full address, exactly like the main one — for example http://backup.example.com:8080':
      "La dirección completa, igual que la principal; por ejemplo http://backup.example.com:8080",
  'Server address': "Dirección del servidor",
  'Add': "Añadir",
  'Edit login': "Editar cuenta",
  'Delete playlist': "Eliminar lista",
  'This Playlist': "Esta lista",
  'Playlist enabled': "Lista activada",
  'Frees up this account\'s stream slot for another device — stops playback here immediately, keeps everything else intact.':
      "Libera la conexión de esta cuenta para otro dispositivo: detiene la reproducción aquí al instante y conserva todo lo demás.",
  'Login Details': "Datos de la cuenta",
  'Server': "Servidor",
  'Expires': "Caduca",
  'Max connections': "Conexiones máx.",
  'Backup Servers': "Servidores de respaldo",
  'None yet. If your provider gave you more than one server address for this same account, add them here and this playlist will try them in order whenever the main one can\'t be reached.':
      "Ninguno todavía. Si tu proveedor te dio más de una dirección de servidor para esta misma cuenta, añádelas aquí y la lista las probará en orden cuando la principal no responda.",
  'Same username and password as above — only the address differs. Tried in order, a few seconds apart, and whichever answers is used first next time.':
      "Mismo usuario y contraseña que arriba; solo cambia la dirección. Se prueban en orden, con unos segundos entre cada uno, y el que responda se usa primero la próxima vez.",
  'Content Overview': "Resumen del contenido",
  'Not loaded yet.': "Aún no cargado.",
  '{p} live channels · {p2} movie categories · {p3} TV show categories':
      "{p} canales en vivo · {p2} categorías de películas · {p3} categorías de series",
  '{p} live · {p2} movies · {p3} TV shows':
      "{p} en vivo · {p2} películas · {p3} series",
  'Last updated: {p}': "Última act.: {p}",
  'Added: {p}': "Añadida: {p}",
  'Hidden Channels': "Canales ocultos",
  'Hide a group here and it\'s excluded from the background download too, not just the browse tabs.':
      "Un grupo oculto aquí también se excluye de la descarga en segundo plano, no solo de las pestañas.",
  'Full Catalog Sync': "Sincronización completa del catálogo",
  'Update content every': "Actualizar contenido cada",
  '1 day': "1 día",
  '{d} days': "{d} días",
  'A stale sync prompts "Update content now?" on launch instead of running automatically.':
      "Una sincronización antigua muestra «¿Actualizar el contenido ahora?» al iniciar, en vez de hacerse sola.",
  'in use': "en uso",
  'Remove {server}': "Quitar {server}",
  'Which playlist\'s groups show first — set independently for each tab below.':
      "Qué lista muestra sus grupos primero; se ajusta por separado para cada pestaña de abajo.",
  'Add another enabled playlist to set a priority between them.':
      "Añade otra lista activada para fijar una prioridad entre ellas.",
  'Live TV order': "Orden de TV en vivo",
  'Movies order': "Orden de películas",
  'TV Shows order': "Orden de series",
  'Move up': "Subir",
  'Move down': "Bajar",
  'Playlist added': "Lista añadida",
  'This playlist is disabled on this device — enable it in Settings > Playlist Manager to watch.':
      "Esta lista está desactivada en este dispositivo: actívala en Ajustes > Gestor de listas para ver.",

  // ── Profiles / PIN ───────────────────────────────────────────────────
  'Profiles': "Perfiles",
  'Add Profile': "Añadir perfil",
  'Rename profile': "Renombrar perfil",
  'Delete "{name}"?': "¿Eliminar «{name}»?",
  'Their favorites, hidden groups, and watch history are deleted too. This can\'t be undone.':
      "También se eliminan sus favoritos, grupos ocultos e historial. No se puede deshacer.",
  'Switch to another profile before deleting this one':
      "Cambia a otro perfil antes de eliminar este",
  'Delete profile': "Eliminar perfil",
  'This is the active profile': "Este es el perfil activo",
  'Switch to this profile': "Cambiar a este perfil",
  'Rename': "Renombrar",
  'What this profile can see': "Lo que puede ver este perfil",
  'Groups — {name}': "Grupos — {name}",
  'Hidden channels — {name}': "Canales ocultos — {name}",
  'For a child — hides every group, including adult content, by default. A parent unhides specific categories per playlist afterward in Group Management. A PIN is required to switch away from this profile or to open Settings while it\'s active.':
      "Para un niño: oculta todos los grupos por defecto, incluido el contenido para adultos. Después, un adulto muestra categorías concretas por lista en Gestión de grupos. Se necesita un PIN para salir de este perfil o abrir Ajustes mientras esté activo.",
  'Create': "Crear",
  'Incorrect PIN': "PIN incorrecto",
  "PINs didn't match — try again": "Los PIN no coinciden; inténtalo de nuevo",
  'Enter PIN': "Escribe el PIN",
  'Confirm PIN': "Confirma el PIN",
  'Set a PIN': "Elige un PIN",
  'Too many attempts — try again in {p}s':
      "Demasiados intentos; inténtalo de nuevo en {p} s",

  // ── Settings menu ────────────────────────────────────────────────────
  'M3U URL or Xtream Codes login': "URL M3U o cuenta Xtream Codes",
  'Every playlist: login, groups, enable/disable':
      "Todas las listas: cuenta, grupos, activar/desactivar",
  'Separate favorites, history & hidden groups per viewer':
      "Favoritos, historial y grupos ocultos separados por persona",
  'Language and history': "Idioma e historial",
  'Language, startup, Multiview and history':
      "Idioma, inicio, Multivista e historial",
  'Theme': "Tema",
  'Clock, accent color, layout': "Reloj, color, diseño",
  'Auto-refresh, channel matching & pairing, clear cache':
      "Act. automática, asociación y emparejado de canales, borrar caché",
  'TMDB (Release Dates)': "TMDB (fechas de estreno)",
  'Optional key for sorting by real release date':
      "Clave opcional para ordenar por fecha de estreno real",
  'Download and install the latest release':
      "Descargar e instalar la última versión",
  'Version —': "Versión —",
  'Version {version}': "Versión {version}",

  // ── Theme ────────────────────────────────────────────────────────────
  'Show clock': "Mostrar reloj",
  'Displays the current time in the top bar':
      "Muestra la hora en la barra superior",
  'Theme color': "Color del tema",
  'Auto picks phone vs TV layout by screen size — force one if your box isn\'t detected correctly.':
      "«Auto» elige el diseño de teléfono o TV según la pantalla; fuerza uno si tu equipo no se detecta bien.",
  'Live TV guide': "Guía de TV en vivo",
  'Timeline shows every channel at once, on a scrollable schedule grid, instead of one channel\'s now/next at a time.':
      "«Parrilla» muestra todos los canales a la vez en una cuadrícula desplazable, en lugar del ahora/después de un solo canal.",
  'Full-screen video behind the guide':
      "Vídeo a pantalla completa detrás de la guía",
  'The live channel fills the screen behind a see-through guide showing 3 rows':
      "El canal en directo llena la pantalla detrás de una guía transparente de 3 filas",
  'Auto': "Auto",
  'Phone': "Teléfono",
  'Timeline': "Parrilla",
  'Platinum': "Platino",
  'Rosé': "Rosé",
  'Neon Purple': "Morado neón",
  'Neon Green': "Verde neón",
  'Habs': "Habs",
  'Dark / Gold': "Negro / Oro",

  // ── TMDB ─────────────────────────────────────────────────────────────
  'Cleared — TMDB sorting is now off':
      "Borrada: el orden por TMDB está desactivado",
  'Saved — key verified with TMDB ✓': "Guardada: clave verificada con TMDB ✓",
  'Saved, but TMDB rejected this key — double-check it\'s correct':
      "Guardada, pero TMDB rechazó esta clave; revisa que sea correcta",
  'What\'s New refreshed from TMDB': "Novedades actualizadas desde TMDB",
  'TMDB (The Movie Database) is a free, independent movie and TV database — not your IPTV provider. Adding your own free TMDB key lets iptv-app look up a title\'s actual real-world release date, which powers two things: a "TMDB" sort option on any group\'s "Expand catalog" screen, and a more accurate "What\'s New" row (ordered by real release date instead of just when your provider added the title).':
      "TMDB (The Movie Database) es una base de datos de películas y series gratuita e independiente; no es tu proveedor IPTV. Con tu propia clave gratuita de TMDB, iptv-app consulta la fecha de estreno real de un título, lo que sirve para dos cosas: una opción de orden «TMDB» en la pantalla «Catálogo completo» de cada grupo, y una fila de «Novedades» más precisa (ordenada por fecha de estreno real en vez de por cuándo la añadió tu proveedor).",
  'This is completely optional and free — iptv-app works 100% without it. Without a key, sorting just falls back to whenever your provider added or updated each title, which is still available and works fine on its own.':
      "Es totalmente opcional y gratis: iptv-app funciona al 100 % sin ella. Sin clave, el orden usa la fecha en que tu proveedor añadió o actualizó cada título, que también funciona bien.",
  'To get one: create a free account at themoviedb.org, then generate an API key under Settings > API (choose "Personal use" when asked) and paste it below. iptv-app never collects or shares it — it\'s stored only on this device.':
      "Para obtenerla: crea una cuenta gratis en themoviedb.org, genera una clave API en Settings > API (elige «Personal use» cuando te lo pida) y pégala abajo. iptv-app nunca la recopila ni la comparte; solo se guarda en este dispositivo.",
  'TMDB API Key': "Clave API de TMDB",
  'What\'s New only re-checks TMDB about once a week on its own. Use this to force it right now instead of waiting — useful right after saving a key for the first time.':
      "Novedades solo vuelve a consultar TMDB más o menos una vez por semana. Usa esto para forzarlo ahora mismo; útil justo después de guardar una clave por primera vez.",
  'Refresh What\'s New Now': "Actualizar Novedades ahora",
  'This product uses the TMDB API but is not endorsed or certified by TMDB.':
      "Este producto usa la API de TMDB, pero no está respaldado ni certificado por TMDB.",

  // ── Loading phases / connection ──────────────────────────────────────
  'No Title': "Sin título",
  'Reconnecting...': "Reconectando…",
  'Trying to reconnect on backup servers ({p}/{candidates})...':
      "Intentando reconectar en servidores de respaldo ({p}/{candidates})…",
  'Finding live channels... ({p} found)':
      "Buscando canales en vivo… ({p} encontrados)",
  'Finding movies... ({p} found)': "Buscando películas… ({p} encontradas)",
  'Finding TV shows... ({p} found)': "Buscando series… ({p} encontradas)",
  'Connecting to {label} ({p}/{candidates})...':
      "Conectando a {label} ({p}/{candidates})…",
  'Connected to {label}': "Conectado a {label}",
  'Connecting to {label} ({p}/{candidates})... failed':
      "Conectando a {label} ({p}/{candidates})… error",
  'Finding live channels...': "Buscando canales en vivo…",
  'Finding live channels... ({loadedLive} found)':
      "Buscando canales en vivo… ({loadedLive} encontrados)",
  'Finding movie categories...': "Buscando categorías de películas…",
  'Finding movies... ({vodCategories} categories found)':
      "Buscando películas… ({vodCategories} categorías encontradas)",
  'Finding TV show categories...': "Buscando categorías de series…",
  'Finding TV shows... ({seriesCategories} categories found)':
      "Buscando series… ({seriesCategories} categorías encontradas)",
  'Loading full catalog in the background — {p}':
      "Cargando el catálogo completo en segundo plano — {p}",
  'Ready': "Listo",
  '{done}/{total} categories': "{done}/{total} categorías",

  'Failed to load EPG (HTTP {code})': "No se pudo cargar la guía (HTTP {code})",
  'Failed to load playlist from {host} (HTTP {code})':
      "No se pudo cargar la lista desde {host} (HTTP {code})",
  'Xtream request to {server} failed: {action} (HTTP {code})':
      "Falló la solicitud Xtream a {server}: {action} (HTTP {code})",
  'Main': "Principal",
  '{h}h ': "{h} h ",

  // ── Small widgets ────────────────────────────────────────────────────
  'Unpin': "Quitar de favoritos",
  'Pin as favorite': "Fijar como favorito",
  'Next: {p}': "Después: {p}",
  'NOW: {title} ({p}-{p2})': "AHORA: {title} ({p}-{p2})",
  'NEXT: {title} ({p})': "DESPUÉS: {title} ({p})",
  'Hold ': "Mantén ",
  ' to resume': " para reanudar",
  'Expand sidebar': "Expandir panel",
  'Collapse sidebar': "Contraer panel",
  'Pinned channels': "Canales fijados",
  'League manager': "Gestor de ligas",
  'Your leagues': "Tus ligas",
  'League bank': "Banco de ligas",
  'Every league is added.': "Todas las ligas están añadidas.",
  'Added · hold to send back': "Añadida · mantén para devolverla",
  '{name} is back in the league bank': "{name} volvió al banco de ligas",
  'England': "Inglaterra",
  'Spain': "España",
  'Germany': "Alemania",
  'Italy': "Italia",
  'France': "Francia",
  'Europe': "Europa",
  'Cups': "Copas",
  'Americas': "Américas",
  'World': "Mundo",
  'Women': "Femenino",
  'Basketball': "Baloncesto",
  'Hockey': "Hockey",
  'Baseball': "Béisbol",
  'Other': "Otros",
  'Golf': "Golf",
  'Tennis': "Tenis",
  'Fighting': "Combate",
  'Motorsport': "Motor",
  'Always for {name}': "Siempre para {name}",
  'Best for a channel that carries the whole series':
      "Ideal para un canal que emite toda la serie",
  'Next game: {date}': "Próximo partido: {date}",
  'No upcoming games listed yet for this league.':
      "Todavía no hay próximos partidos para esta liga.",
  'Transfer to another device': "Transferir a otro dispositivo",
  'Copy playlists, favorites and settings over Wi-Fi':
      "Copia listas, favoritos y ajustes por Wi-Fi",
  'Copies your playlists, favorites, hidden groups, profiles, watch progress and settings to another device. On the same Wi-Fi it goes straight across; anywhere else it goes through an encrypted upload only the code can open. Channels, movies and the guide download again on the new device.':
      "Copia tus listas, favoritos, grupos ocultos, perfiles, progreso y ajustes a otro dispositivo. En el mismo Wi-Fi pasa directamente; desde otro lugar pasa por una subida cifrada que solo el código puede abrir. Los canales, películas y la guía se vuelven a descargar en el nuevo dispositivo.",
  'This setup is too big to upload. Use the same-Wi-Fi transfer instead.':
      "Esta configuración es demasiado grande para subirla. Usa la transferencia por el mismo Wi-Fi.",
  'Couldn\'t reach the iptv-app transfer server. Check this device\'s internet connection and try again.':
      "No se pudo contactar con el servidor de transferencia de iptv-app. Revisa la conexión a internet de este dispositivo y vuelve a intentarlo.",
  '{n} hour': "{n} hora",
  '{n} hours': "{n} horas",
  '{n} day': "{n} día",
  '{n} days': "{n} días",
  'Your setup is encrypted on this device and uploaded. Any device that enters the code can copy it until it expires — even with this device turned off. How long should it stay available?':
      "Tu configuración se cifra en este dispositivo y se sube. Cualquier dispositivo que escriba el código puede copiarla hasta que caduque, incluso con este dispositivo apagado. ¿Cuánto tiempo debe estar disponible?",
  'Encrypting and uploading…': "Cifrando y subiendo…",
  'Works on any network until {time}':
      "Funciona en cualquier red hasta: {time}",
  'Anyone with this code can copy your setup, playlist logins included. Changes made after this upload aren\'t in it — upload again to update it.':
      "Cualquiera con este código puede copiar tu configuración, incluidos los accesos de las listas. Los cambios posteriores a esta subida no están incluidos: vuelve a subirla para actualizarla.",
  'Upload again': "Volver a subir",
  'Delete now': "Eliminar ahora",
  'Nothing was found for that code. Check it — the upload may also have expired or been deleted.':
      "No se encontró nada con ese código. Revísalo; la subida también puede haber caducado o haberse eliminado.",
  '9 digits on the same Wi-Fi, 16 digits over the internet':
      "9 dígitos en el mismo Wi-Fi, 16 por internet",
  '24-hour clock': "Reloj de 24 horas",
  'Times show as 21:30': "Las horas se muestran así: 21:30",
  'Times show as 9:30 PM': "Las horas se muestran así: 9:30 PM",
  'Welcome back, legend':
      "Bienvenido de nuevo, leyenda",
  'No favourites yet. Hold Select on a poster or a group to add one.':
      "Todavía no hay favoritos. Mantén OK sobre un póster o un grupo para añadir uno.",
  'Rotate': "Girar",
  'You have great taste':
      "Tienes un gusto excelente",
  'Looking sharp today':
      "Hoy te ves increíble",
  'You make this place better':
      "Haces de este lugar algo mejor",
  'Hey superstar':
      "Hola, superestrella",
  'You deserve this break':
      "Te mereces este descanso",
  'You\'re doing amazing':
      "Lo estás haciendo genial",
  'Hello, wonderful you':
      "Hola, persona maravillosa",
  'Smart choice, as always':
      "Buena elección, como siempre",
  'You light up the room':
      "Iluminas la habitación",
  'Keep shining, you\'ve got this':
      "Sigue brillando, tú puedes",
  'You earned some fun today':
      "Hoy te ganaste un poco de diversión",
  'The world is better with you in it':
      "El mundo es mejor contigo",
  'Hey champ, welcome in':
      "Hola, campeón, adelante",
  'Send from this device': "Enviar desde este dispositivo",
  'Shows a code to enter on the other device':
      "Muestra un código para escribir en el otro dispositivo",
  'Both devices on the same Wi-Fi?': "¿Los dos dispositivos en el mismo Wi-Fi?",
  'Send directly, without uploading': "Enviar directamente, sin subir nada",
  'Receive on this device': "Recibir en este dispositivo",
  'Replaces this device\'s setup with the other one\'s':
      "Reemplaza la configuración de este dispositivo por la del otro",
  'This device isn\'t on a Wi-Fi or wired home network.':
      "Este dispositivo no está en una red Wi-Fi o por cable.",
  'Sent! Finish on the other device.':
      "¡Enviado! Termina en el otro dispositivo.",
  'This code has expired. Go back and start again.':
      "Este código caducó. Vuelve atrás y empieza de nuevo.",
  'On the other device, open Settings > Transfer to another device > Receive, and enter:':
      "En el otro dispositivo, abre Ajustes > Transferir a otro dispositivo > Recibir y escribe:",
  'This device: {address} · the code works once, for 10 minutes':
      "Este dispositivo: {address} · el código sirve una vez, durante 10 minutos",
  'Couldn\'t find the other device. Check the code, and that both devices are on the same Wi-Fi with the code still showing.':
      "No se encontró el otro dispositivo. Revisa el código y que ambos estén en el mismo Wi-Fi con el código todavía en pantalla.",
  'That code isn\'t right. Check it on the other device.':
      "Ese código no es correcto. Revísalo en el otro dispositivo.",
  'That code has expired or was already used. Start again on the other device.':
      "Ese código caducó o ya se usó. Empieza de nuevo en el otro dispositivo.",
  'The transfer didn\'t go through. Try again.':
      "La transferencia no se completó. Inténtalo de nuevo.",
  'Transfer complete': "Transferencia completa",
  'iptv-app will close now. Open it again to load your playlists.':
      "iptv-app se cerrará ahora. Ábrelo de nuevo para cargar tus listas.",
  'Enter the code shown on the other device':
      "Escribe el código que aparece en el otro dispositivo",
  'Ready to copy': "Listo para copiar",
  '{playlists} playlists · {profiles} profiles · {favorites} favorites':
      "Listas: {playlists} · Perfiles: {profiles} · Favoritos: {favorites}",
  'This replaces the playlists, favorites and settings on this device.':
      "Esto reemplaza las listas, favoritos y ajustes de este dispositivo.",
  'Replace my data': "Reemplazar mis datos",
  'Enter the address shown under the code on the other device (This device: …)':
      "Escribe la dirección que aparece bajo el código en el otro dispositivo (Este dispositivo: …)",
  'Code: {code}': "Código: {code}",
  'Type the address instead': "Escribir la dirección",
  '{n} playlist': "{n} lista",
  '{n} playlists': "{n} listas",
  '{n} profile': "{n} perfil",
  '{n} profiles': "{n} perfiles",
  '{n} favorite': "{n} favorito",
  '{n} favorites': "{n} favoritos",
  'Clear favourites?':
      "¿Borrar favoritos?",
  "Removes every starred item and favourite group from this tab's Favourites.":
      "Quita todos los elementos marcados y grupos favoritos de los Favoritos de esta pestaña.",
  'Favourites cleared.':
      "Favoritos borrados.",
  'Delete watched history?': "¿Eliminar el historial de visualización?",
  'Removes the History list of live channels.':
      "Borra la lista Historial de canales en directo.",
  'Watched history deleted.': "Historial de visualización eliminado.",
  'NFL RedZone channel': "Canal NFL RedZone",
  // Series detail screen
  'Resume {code}': "Reanudar {code}",
  'Play {code}': "Reproducir {code}",
  '{n} seasons': "{n} temporadas",
  '{n} episodes': "{n} episodios",
  '1 episode': "1 episodio",
  '{m} min': "{m} min",
  '{h} h {m} min': "{h} h {m} min",
  'Episode {n}': "Episodio {n}",
  'Watched': "Visto",
  'More': "Más",
  'Watching': "Viendo",
  'Marked as watched': "Marcado como visto",
  'Marked as unwatched': "Marcado como no visto",
  'Hold to mark as watched': "Mantén pulsado para marcar como visto",
  'Hold to mark as unwatched': "Mantén pulsado para marcar como no visto",
  'Cast: {names}': "Reparto: {names}",
  'Director: {names}': "Dirección: {names}",
  'Specials': "Especiales",
  'Movie and TV artwork and data may come from TMDB (The Movie Database).':
      "Las imágenes y los datos de películas y series pueden provenir de TMDB (The Movie Database).",
  '{appName} {version} is available': "{appName} {version} está disponible",
  "What's new:": "Novedades:",
  'A new version is ready to install.': "Hay una nueva versión lista para instalar.",
  'Skip this version': "Omitir esta versión",
  'Later': "Más tarde",
  'See all · stats': "Ver todo · estadísticas",
  'Live games': "Partidos en vivo",
  'Click a game for its stats': "Haz clic en un partido para ver sus estadísticas",
  'No games are live right now': "No hay partidos en vivo ahora",
  'RED ZONE': "ZONA ROJA",
  'No channel': "Sin canal",
  'Watch on {channel}': "Ver en {channel}",
  'No channel found. Hold OK on the game in {tab} to pick one.': "No se encontró canal. Mantén OK sobre el partido en {tab} para elegir uno.",
  '▲▼ scroll · Back closes': "▲▼ desplazar · Atrás cierra",
  'Passing': "Pases",
  'Rushing': "Carrera",
  'Receiving': "Recepción",
  'Defense': "Defensa",
  'Kicking': "Pateo",
  'Forwards': "Delanteros",
  'Defensemen': "Defensas",
  'Goalies': "Porteros",
  'Batting': "Bateo",
  'Pitching': "Pitcheo",
  'Players': "Jugadores",
  'No stats for this game yet.': "Aún no hay estadísticas de este partido.",
  'Top performers': "Mejores jugadores",
  'Injuries': "Lesiones",
  'Goals': "Goles",
  'pen.': "pen.",
  'Team stats': "Estadísticas de equipo",
  'OK = stats · hold OK = channels · ▶❚❚ = watch': "OK = estadísticas · mantener OK = canales · ▶❚❚ = ver",
  '{channel} · full screen': "{channel} · pantalla completa",
  // ── Archive tab ──────────────────────────────────────────────────────
  "Add a source": "Añadir una fuente",
  "Couldn't load the catalog: {error}": "No se pudo cargar el catálogo: {error}",
  "Couldn't reach that link.": "No se pudo acceder a ese enlace.",
  "No playable stream for this title.": "No hay ningún stream reproducible para este título.",
  "No sources yet.": "Todavía no hay fuentes.",
  "None of your sources has TV shows.": "Ninguna de tus fuentes tiene series.",
  "None of your sources has movies.": "Ninguna de tus fuentes tiene películas.",
  "Nothing here yet.": "Aún no hay nada aquí.",
  "Refresh": "Actualizar",
  "Source link (ends with manifest.json)": "Enlace de la fuente (termina en manifest.json)",
  "That source is already in the list.": "Esa fuente ya está en la lista.",
  "This source lists no episodes for this show.": "Esta fuente no muestra episodios para esta serie.",
  "iptv-app ships no sources. The titles you open are requested from the source you added; nothing else is shared.": "iptv-app no incluye fuentes. Los títulos que abres se piden a la fuente que añadiste; no se comparte nada más.",
  "Your sources": "Tus fuentes",
  "{n} TV show catalogs": "{n} catálogos de series",
  "{n} movie catalogs": "{n} catálogos de películas",
  "Check the link here, then press Add.": "Revisa el enlace aquí y pulsa Añadir.",
  "Hide Movies": "Ocultar Películas",
  "Hide TV Shows": "Ocultar Series",
  "Paste the link and tap Send to TV.": "Pega el enlace y toca Enviar a la TV.",
  "Removes the Movies tab and movie search results.": "Quita la pestaña Películas y las películas de la búsqueda.",
  "Removes the TV Shows tab and show search results.": "Quita la pestaña Series y las series de la búsqueda.",
  "Typing a long link with a remote is painful. Scan this code with your phone camera and paste the link there — it appears here for you to check and add.": "Escribir un enlace largo con el mando es un suplicio. Escanea este código con la cámara del móvil y pega ahí el enlace — aparecerá aquí para que lo revises y lo añadas.",
  // Archive: rows, search, stream picker
  'Popular': 'Populares',
  'New': 'Novedades',
  'Featured': 'Destacados',
  'Search movies': 'Buscar películas',
  'Search TV shows': 'Buscar series',
  'Title': 'Título',
  'Searching…': 'Buscando…',
  'Clear search': 'Borrar búsqueda',
  'Results for "{query}"': 'Resultados para «{query}»',
  'No results for "{query}"': 'Sin resultados para «{query}»',
  'Choose a stream': 'Elegir una fuente',
  'Stream {n}': 'Fuente {n}',
  // Transfer: Archive tab data
  // Media Hub tab (was Extras, before that Archive) + Multiview toggle
  // Trakt & Simkl (trackers_screen.dart, tracker rows)
  'Watch tracking powered by Trakt and Simkl; iptv-app is not affiliated with or endorsed by either.': "Seguimiento de lo que ves con Trakt y Simkl; iptv-app no está afiliado ni respaldado por ninguno de los dos.",
  'Powered by Trakt (trakt.tv) and Simkl (simkl.com).': "Con la tecnología de Trakt (trakt.tv) y Simkl (simkl.com).",
  'iptv-app is not affiliated with or endorsed by Trakt or Simkl.': "iptv-app no está afiliado ni respaldado por Trakt o Simkl.",
  'Trakt & Simkl': 'Trakt y Simkl',
  'Track what you watch, lists in the Media Hub': 'Registra lo que ves, listas en el Media Hub',
  'Connected as {name} — press OK to disconnect': 'Conectado como {name} — pulsa OK para desconectar',
  'Not available in this build yet': 'Aún no disponible en esta versión',
  'Connect a watch tracker: what you watch in the Media Hub is marked as watched on your account, and your lists show up as Media Hub rows. Nothing is sent unless you connect an account.': 'Conecta un servicio de seguimiento: lo que ves en el Media Hub se marca como visto en tu cuenta y tus listas aparecen como filas en el Media Hub. No se envía nada si no conectas una cuenta.',
  'Watchlist and trending rows, scrobbling': 'Filas de watchlist y tendencias, scrobbling',
  'Watching and plan-to-watch rows, scrobbling': 'Filas viendo y por ver, scrobbling',
  'Titles from your lists play through your stream add-ons (Media Hub sources), by IMDb id. Only titles with an IMDb id are reported.': 'Los títulos de tus listas se reproducen con tus complementos de flujo (fuentes del Media Hub), por id de IMDb. Solo se informan los títulos con id de IMDb.',
  '{name} connected.': '{name} conectado.',
  'Disconnect {name}?': '¿Desconectar {name}?',
  'Its rows leave the Media Hub and plays are no longer reported. Your account itself is untouched.': 'Sus filas salen del Media Hub y las reproducciones ya no se informan. Tu cuenta no se modifica.',
  'Disconnect': 'Desconectar',
  'Couldn\'t reach {name}. Check the connection.': 'No se pudo conectar con {name}. Revisa la conexión.',
  'The code expired. Try again.': 'El código caducó. Inténtalo de nuevo.',
  'Sign-in was not completed. Try again.': 'No se completó el inicio de sesión. Inténtalo de nuevo.',
  'Connect {name}': 'Conectar {name}',
  'On your phone or computer, open': 'En tu teléfono u ordenador, abre',
  'and enter this code:': 'e introduce este código:',
  'Waiting for you to approve…': 'Esperando tu aprobación…',
  'Try again': 'Reintentar',
  'Trakt watchlist': 'Watchlist de Trakt',
  'Trending on Trakt': 'Tendencias en Trakt',
  'Watching on Simkl': 'Viendo en Simkl',
  'Simkl plan to watch': 'Por ver en Simkl',
  // Multiview picker: Live now / Sports shortcuts
  '{n} channels': '{n} canales',
  'No live games on your channels right now': 'Ningún partido en directo en tus canales ahora mismo',
  // Media Hub: Connect Jellyfin / Emby (media_server_screen.dart)
  'Connect Jellyfin / Emby': 'Conectar Jellyfin / Emby',
  'User name': 'Nombre de usuario',
  'Connect': 'Conectar',
  'Enter the server address and your user name.': 'Introduce la dirección del servidor y tu nombre de usuario.',
  'Wrong user name or password.': 'Nombre de usuario o contraseña incorrectos.',
  'This account has no movie or TV library.': 'Esta cuenta no tiene ninguna biblioteca de películas o series.',
  'Couldn\'t find a Jellyfin or Emby server at that address.': 'No se encontró ningún servidor Jellyfin o Emby en esa dirección.',
  'Sign in to your own Jellyfin or Emby server: its movie and TV libraries show up in the Media Hub. Files play as they are stored on the server (no transcoding).': 'Inicia sesión en tu propio servidor Jellyfin o Emby: sus bibliotecas de películas y series aparecen en el Media Hub. Los archivos se reproducen tal como están guardados en el servidor (sin transcodificación).',
  'Your password is only sent to your server. iptv-app keeps the sign-in token the server gives back, not the password.': 'Tu contraseña solo se envía a tu servidor. iptv-app guarda el token de sesión que devuelve el servidor, no la contraseña.',
  'Media Hub': 'Media Hub',
  'Media Hub sources': 'Fuentes de Media Hub',
  'Add-on sources for the Media Hub tab': 'Fuentes de complementos para la pestaña Media Hub',
  'Clear Media Hub?': '¿Borrar Media Hub?',
  'Clear Media Hub': 'Borrar Media Hub',
  'Media Hub cleared.': 'Media Hub borrado.',
  'Include Media Hub tab data': 'Incluir los datos de la pestaña Media Hub',
  'Media Hub sources and their watch progress are sent too': 'También se envían las fuentes de Media Hub y su progreso',
  'The other device keeps its own Media Hub sources': 'El otro dispositivo conserva sus propias fuentes de Media Hub',
  'Add a source to browse films and series. Any source that follows the catalog/stream add-on format works.': 'Añade una fuente para explorar películas y series. Funciona cualquier fuente que siga el formato de complemento catálogo/flujo.',
  'That link isn\'t a Media Hub source (it needs movie or series streams).': 'Ese enlace no es una fuente de Media Hub (necesita flujos de películas o series).',
  'Removes every Media Hub source and its saved catalog from this device.': 'Quita todas las fuentes de Media Hub y su catálogo guardado de este dispositivo.',
  'The Media Hub tab shows films and series from sources you add here. Any source that follows the catalog/stream add-on format works; a source that only offers streams by IMDb id gets its posters and episodes from Cinemeta. Only direct video links are played; torrent links are ignored.': 'La pestaña Media Hub muestra películas y series de las fuentes que añadas aquí. Funciona cualquier fuente que siga el formato de complemento catálogo/flujo; una fuente que solo ofrece flujos por id de IMDb toma sus carátulas y episodios de Cinemeta. Solo se reproducen enlaces de vídeo directos; los enlaces torrent se ignoran.',
  'Hide Media Hub': 'Ocultar Media Hub',
  'Removes the Media Hub tab.': 'Quita la pestaña Media Hub.',
  'Hide Multiview': 'Ocultar Multivista',
  'Removes the Multiview row and the player\'s Open in Multiview button.': 'Quita la fila Multivista y el botón Abrir en Multivista del reproductor.',
  // Extras genre filter
  'Genre': 'Género',
  'All genres': 'Todos los géneros',
  'genre.Action': 'Acción',
  'genre.Adventure': 'Aventura',
  'genre.Animation': 'Animación',
  'genre.Biography': 'Biografía',
  'genre.Comedy': 'Comedia',
  'genre.Crime': 'Crimen',
  'genre.Documentary': 'Documental',
  'genre.Drama': 'Drama',
  'genre.Family': 'Familia',
  'genre.Fantasy': 'Fantasía',
  'genre.History': 'Historia',
  'genre.Horror': 'Terror',
  'genre.Mystery': 'Misterio',
  'genre.Romance': 'Romance',
  'genre.Sci-Fi': 'Ciencia ficción',
  'genre.Sport': 'Deporte',
  'genre.Thriller': 'Suspense',
  'genre.War': 'Bélica',
  'genre.Western': 'Western',
  'genre.Reality-TV': 'Telerrealidad',
  'genre.Talk-Show': 'Programa de entrevistas',
  'genre.Game-Show': 'Concurso',
  // Sports: favourite league
  'OK: show/hide or add · Hold OK: favourite league, or send an added league back to the bank': 'OK: mostrar/ocultar o añadir · Mantén OK: liga favorita, o devolver una liga añadida al banco',
  'Make favourite league': 'Hacerla liga favorita',
  'Remove from favourite': 'Quitar de favorita',
  '{tab} opens on it and its games come first in Live now': '{tab} se abre en ella y sus partidos salen primero en En vivo',
  'Send back to the league bank': 'Devolver al banco de ligas',
  'Favourite league': 'Liga favorita',
  // Player side panel: Pull stats
  '◀ ▶ tabs  ·  OK to watch  ·  Hold OK for stats  ·  Back to close': '◀ ▶ pestañas  ·  OK para ver  ·  Mantén OK: estadísticas  ·  Atrás para cerrar',
  // Sports hero on Windows
  'Click the game again or Enter: full screen  ·  Esc: stop': 'Haz clic otra vez en el partido o Intro: pantalla completa  ·  Esc: detener',
  'Click again: watch here  ·  Hold: pick the channel': 'Clic otra vez: ver aquí  ·  Mantener: elegir el canal',
  // Extras floating Search / Genre bar
  'Movie genres': 'Géneros de películas',
  'TV show genres': 'Géneros de series',
  // Extras: watched history + recent searches
  'Recently watched': 'Vistos recientemente',
  'Clear recent searches': 'Borrar búsquedas recientes',
};
