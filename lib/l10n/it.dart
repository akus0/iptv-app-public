/// Italian UI strings, keyed by the English text in the code (see l10n.dart).
///
/// Standard Italian. TV labels are often narrow, so short forms are used on
/// purpose (AGG., G/V/P for standings, etc.). Keep every `{placeholder}`
/// exactly as in the key. `{s}` is an English-style plural "s" filled in by
/// the code; Italian plurals don't work that way (canale/canali), so those
/// strings are phrased to avoid it.
const Map<String, String> kIt = {
  // ── Startup / catalog sync ───────────────────────────────────────────
  'Starting...': "Avvio…",
  'Content updated': "Contenuti aggiornati",
  'Startup failed:\n{bootstrapError}': "Avvio non riuscito:\n{bootstrapError}",
  'Retry': "Riprova",
  'Your catalog has never been fully synced.':
      "Il catalogo non è mai stato sincronizzato del tutto.",
  'Your catalog was last fully synced earlier today.':
      "Ultima sincronizzazione completa del catalogo: oggi, poco fa.",
  'Your catalog was last fully synced {days} day{s} ago.':
      "Ultima sincronizzazione completa del catalogo: {days} g fa.",
  'Update content now?': "Aggiornare i contenuti adesso?",
  'This can take a few minutes on a large catalog. Skipping opens the app with what\'s already cached.':
      "Con un catalogo grande può richiedere qualche minuto. Se salti, l'app si apre con ciò che è già in cache.",
  'Skip for now': "Non ora",
  'Update': "Aggiorna",
  'Loading movies & TV shows...': "Caricamento di film e serie…",
  'Connecting to server...': "Connessione al server…",
  'Updating Content': "Aggiornamento contenuti",
  '{done} / {total} categories': "{done} / {total} categorie",
  'This happens every few days to keep your catalog current — everyday launches open straight in.':
      "Succede ogni pochi giorni per tenere aggiornato il catalogo; negli altri giorni l'app si apre subito.",
  'Re-checks every visible category for new content. This can take a few minutes on a large catalog.':
      "Ricontrolla ogni categoria visibile in cerca di nuovi contenuti. Con un catalogo grande può richiedere qualche minuto.",
  'Cancel': "Annulla",

  // ── Multiview ────────────────────────────────────────────────────────
  'Multiview': "Multivista",
  'Layout': "Layout",
  '2 channels': "2 canali",
  '4 channels': "4 canali",
  '= audio — click a channel to switch':
      "= audio — clicca un canale per cambiare",
  'Reload': "Ricarica",
  'Change channel': "Cambia canale",
  'Remove': "Rimuovi",
  'Search channels...': "Cerca canali…",
  'Before you start': "Prima di iniziare",
  'Every screen in Multiview is its own connection to your provider. Your playlist must allow at least as many connections as screens you open (see Max connections in Playlist Manager).\n\nIf two screens share an account that allows only one connection, they keep kicking each other off and will freeze or buffer. Tip: use channels from different playlists, one per account.\n\nA screen that freezes restarts on its own. If it doesn\'t, hold Select on it and choose Reload.':
      "Ogni schermo della Multivista è una connessione separata al tuo provider. La tua lista deve consentire almeno tante connessioni quanti sono gli schermi aperti (vedi Connessioni max. in Gestione liste).\n\nSe due schermi condividono un account che consente una sola connessione, si scollegano a vicenda e si bloccano o vanno in buffering. Consiglio: usa canali di liste diverse, una per account.\n\nUno schermo bloccato si riavvia da solo. Se non succede, tieni premuto OK su di esso e scegli Ricarica.",
  'Don\'t show this again': "Non mostrare più",
  'OK': "OK",
  'Couldn\'t start that channel': "Impossibile avviare il canale",
  'Full screen': "Schermo intero",
  'Windowed': "In finestra",
  '4 screens': "4 schermi",
  '2 screens': "2 schermi",
  '= audio — Select to switch, hold Select for options':
      "= audio — OK per cambiare, tieni premuto OK per le opzioni",
  'Pick a channel': "Scegli un canale",
  'No channels found': "Nessun canale trovato",
  'Open in Multiview': "Apri in Multivista",

  // ── Player ───────────────────────────────────────────────────────────
  'Recall — recently watched': "Recenti — visti di recente",
  'No other live channels watched yet this session.':
      "Nessun altro canale in diretta visto in questa sessione.",
  'Recall — go back to a recent channel': "Recenti — torna a un canale recente",
  'Remove from favorites': "Rimuovi dai preferiti",
  'Add to favorites': "Aggiungi ai preferiti",
  'Reload channel': "Ricarica canale",
  'Previous episode': "Episodio precedente",
  'Next episode': "Episodio successivo",
  'Ending now': "In chiusura",
  '{minutes} min left': "Mancano {minutes} min",
  'Back': "Indietro",
  'Fit to screen': "Adatta allo schermo",
  'Fill screen': "Riempi lo schermo",
  'Closed captions (CC) — if the channel broadcasts them': "Sottotitoli (CC) — se il canale li trasmette",
  'Up Next': "A seguire",
  'Playing in {countdown}s': "Riproduzione tra {countdown} s",
  'Playing now...': "Riproduzione…",
  'Play now': "Riproduci ora",
  'Dismiss': "Ignora",
  'Select a channel to start watching': "Scegli un canale per iniziare",
  'Switch to {p}: {name}': "Passa a {p}: {name}",
  'Switch to {playlistName}: {name}': "Passa a {playlistName}: {name}",
  'Technical details': "Dettagli tecnici",
  'This device\'s video decoder couldn\'t play this stream — likely 4K HDR (HEVC 10-bit). If your provider offers an HD (non-4K) version of this channel or title, try that. If another app plays this stream on this device, please report it with a photo of the technical details below.':
      "Il decoder video di questo dispositivo non è riuscito a riprodurre questo flusso; probabilmente è 4K HDR (HEVC 10 bit). Se il tuo provider offre una versione HD (non 4K) di questo canale o titolo, prova quella. Se un'altra app riproduce questo flusso su questo dispositivo, segnalacelo con una foto dei dettagli tecnici qui sotto.",
  'Playback error:\n{raw}': "Errore di riproduzione:\n{raw}",
  'Subtitles': "Sottotitoli",
  'Off': "Disattivati",
  'Forced': "Forzati",
  'Online':
      'Online',
  'Search online subtitles':
      'Cerca sottotitoli online',
  'From your add-ons (Settings > Add-ons)':
      'Dai tuoi componenti (Impostazioni > Componenti aggiuntivi)',
  'Online subtitles':
      'Sottotitoli online',
  'No subtitles found for this title.':
      'Nessun sottotitolo trovato per questo titolo.',
  "Couldn't download that subtitle. Try another.":
      'Impossibile scaricare questo sottotitolo. Provane un altro.',
  'Add-ons':
      'Componenti aggiuntivi',
  'Online subtitles in more languages':
      'Sottotitoli online in più lingue',
  'Remove {name}?':
      'Rimuovere {name}?',
  "That link isn't a subtitle add-on (only subtitle add-ons are supported).":
      'Questo link non è un componente di sottotitoli (sono supportati solo quelli).',
  'That add-on is already in the list.':
      "Questo componente è già nell'elenco.",
  '{name} added.':
      '{name} aggiunto.',
  "Add-ons find subtitles online for movies and episodes, in many languages. They are free community services, separate from your provider — iptv-app only uses them for subtitles. Turn one on, then pick \"Search online subtitles\" in the player's Subtitles button.":
      'I componenti aggiuntivi trovano sottotitoli online per film ed episodi, in molte lingue. Sono servizi gratuiti della community, separati dal tuo provider — iptv-app li usa solo per i sottotitoli. Attivane uno, poi scegli «Cerca sottotitoli online» nel pulsante Sottotitoli del player.',
  'Subtitle add-ons':
      'Componenti per sottotitoli',
  'Subtitles in 60+ languages from OpenSubtitles.org':
      'Sottotitoli in oltre 60 lingue da OpenSubtitles.org',
  'Hold OK to remove':
      'Tieni premuto OK per rimuovere',
  'Add an add-on':
      'Aggiungi un componente',
  'Add-on link (ends with manifest.json)':
      'Link del componente (termina con manifest.json)',
  'Only subtitle add-ons work here. When one is on, the title and episode you are watching are sent to it to find subtitles; nothing else is shared.':
      "Qui funzionano solo componenti per sottotitoli. Quando uno è attivo, gli vengono inviati il titolo e l'episodio che guardi per trovare i sottotitoli; non viene condiviso nient'altro.",
  'Looking for {language} subtitles…':
      "Cerco sottotitoli in {language}…",
  'No {language} subtitles online for this title.':
      "Nessun sottotitolo in {language} online per questo titolo.",
  'Track {id}': "Traccia {id}",
  'Audio Track': "Traccia audio",
  'Audio track': "Traccia audio",

  // ── Catalog / browse ─────────────────────────────────────────────────
  'Sort': "Ordina",
  'Default': "Predefinito",
  'A to Z': "A-Z",
  'Z to A': "Z-A",
  'Rating (high to low)': "Voto (dal più alto)",
  'Date added/updated': "Data aggiunta/agg.",
  'Fetching TMDB release dates... {done}/{total}':
      "Recupero date di uscita da TMDB… {done}/{total}",
  'Added to Favorites': "Aggiunto ai preferiti",
  'Removed from Favorites': "Rimosso dai preferiti",
  'No items in this group.': "Nessun elemento in questo gruppo.",
  'Re-checks your M3U playlist URL(s) for new content.':
      "Ricontrolla l'URL delle tue liste M3U in cerca di nuovi contenuti.",
  'Set your playlist source in Settings first.':
      "Prima imposta la tua lista nelle Impostazioni.",
  'Continue Watching': "Continua a guardare",
  'Search': "Cerca",
  'Update content': "Agg. contenuti",
  'Update EPG now': "Agg. guida",
  'Settings': "Impostazioni",
  'No TV shows found. Pick a category on the left.':
      "Nessuna serie trovata. Scegli una categoria a sinistra.",
  'No channels found.': "Nessun canale trovato.",
  'Loading playlist...': "Caricamento lista…",
  'Failed to load playlist.': "Impossibile caricare la lista.",
  'Open Settings': "Apri Impostazioni",
  '{p}% watched': "Visto al {p}%",
  'Resume': "Riprendi",
  'Play': "Riproduci",
  'Restart': "Dall'inizio",
  'Failed to load episodes.': "Impossibile caricare gli episodi.",
  'No episodes found.': "Nessun episodio trovato.",
  'Season {season}': "Stagione {season}",
  'Expand catalog': "Catalogo completo",
  'Browse': "Sfoglia",
  'Playlist': "Lista",
  'Previous': "Precedente",
  'Next': "Successivo",
  'Loading...': "Caricamento…",
  'Loading…': "Caricamento…",
  'No recently added movies yet': "Ancora nessun film aggiunto di recente",
  'Loading movie categories...': "Caricamento categorie film…",
  'No recently added shows yet': "Ancora nessuna serie aggiunta di recente",
  'Loading TV show categories...': "Caricamento categorie serie…",
  "What's New": "Novità",

  // ── Search ───────────────────────────────────────────────────────────
  'Switch Profile': "Cambia profilo",
  'Restricted': "Limitato",
  'Search everything...': "Cerca ovunque…",
  'Search everything... (press OK to type)': "Cerca ovunque… (OK per scrivere)",
  'Still loading the full catalog in the background ({warmCatalogDone}/{warmCatalogTotal} categories) — some results may not show up yet.':
      "Il catalogo completo si sta ancora caricando in background ({warmCatalogDone}/{warmCatalogTotal} categorie); alcuni risultati potrebbero mancare.",
  'Search Live TV, Movies & TV Shows': "Cerca in TV in diretta, film e serie",
  'Recent searches': "Ricerche recenti",
  'Clear': "Cancella",
  'Live TV': "TV in diretta",
  'Movies': "Film",
  'TV Shows': "Serie TV",
  'Nothing found': "Nessun risultato",

  // ── Sports ───────────────────────────────────────────────────────────
  'Sports': "Sport",
  'this team': "questa squadra",
  'My Teams': "Le mie squadre",
  'Last channels': "Ultimi canali",
  '◀ ▶ tabs  ·  OK to watch  ·  Back to close':
      "◀ ▶ schede  ·  OK per guardare  ·  Indietro per chiudere",
  'None of your teams play today.': "Nessuna delle tue squadre gioca oggi.",
  'Follow teams from {tab} > Standings to see them here.':
      "Segui le squadre da {tab} > Classifica per vederle qui.",
  'No games from your leagues are live right now.':
      "Nessuna partita dei tuoi campionati è in diretta ora.",
  'Hold OK on a team to unfollow · on a game to pick the channel':
      "Tieni premuto OK su una squadra per non seguirla più · su una partita per scegliere il canale",
  'Add team': "Aggiungi squadra",
  'Follow one from Standings': "Seguine una dalla classifica",
  'Could not load': "Caricamento non riuscito",
  'Follow your teams to see them here': "Segui le tue squadre per vederle qui",
  'Follow another team': "Segui un'altra squadra",
  'Add team opens Standings: hold OK on a team to follow it.':
      "«Aggiungi squadra» apre la classifica: tieni premuto OK su una squadra per seguirla.",
  'This team could not be loaded. Check the connection.':
      "Impossibile caricare questa squadra. Controlla la connessione.",
  'Next 2 weeks': "Prossime 2 settimane",
  'No games in the next two weeks.':
      "Nessuna partita nelle prossime due settimane.",
  'vs': "vs",
  'at': "@",
  'Today {time}': "Oggi {time}",
  'Tomorrow {time}': "Domani {time}",
  'Last game: {opponent} · Final': "Ult. partita: {opponent} · Finale",
  'Last game: {result} {mine}-{other} {opponent}':
      "Ult. partita: {result} {mine}-{other} {opponent}",
  'LIVE': "LIVE",
  'Looking…': "Ricerca…",
  'TEAM': "SQUADRA",
  'Later today': "Più tardi oggi",
  'Tomorrow': "Domani",
  'Not played': "Non giocate",
  'Scheduled': "In programma",
  'Live now': "In diretta",
  'Final': "Finale",
  'All': "Tutto",
  'Edit leagues': "Campionati",
  'Scores hidden': "Risultati nascosti",
  'Scores shown': "Risultati visibili",
  'Yesterday': "Ieri",
  'Today': "Oggi",
  'Standings': "Classifica",
  '{name} standings': "Classifica {name}",
  '{name} championship': "Campionato {name}",
  'No games on this day for your leagues':
      "Nessuna partita in questo giorno nei tuoi campionati",
  'Try another day, or add leagues with Edit leagues.':
      "Prova un altro giorno o aggiungi campionati con il pulsante Campionati.",
  'Live now  {count}': "In diretta  {count}",
  'Live': "In diretta",
  'Starts in {p}{p2}m': "Inizia tra {p}{p2} min",
  'Looking for the channel…': "Ricerca del canale…",
  'No channel found — OK to pick one':
      "Nessun canale trovato — OK per sceglierne uno",
  'Hold OK to pick or swap the channel':
      "Tieni premuto OK per scegliere o cambiare canale",
  'Hold OK: pick the channel  ·  ▶❚❚: watch here':
      "Tieni premuto OK: scegli il canale  ·  ▶❚❚: guarda qui",
  'Tap the game again: full screen  ·  Back: stop':
      "Tocca di nuovo la partita: schermo intero  ·  Indietro: ferma",
  'Tap: watch here  ·  Hold: pick the channel':
      "Tocca: guarda qui  ·  Tieni premuto: scegli il canale",
  'Play here': "Riproduci qui",
  '{channel} · plays at the top of {tab}':
      "{channel} · in onda in cima a {tab}",
  '▶❚❚: watch this game  ·  Back: playing game':
      "▶❚❚: guarda questa partita  ·  Indietro: partita in corso",
  'OK: full screen  ·  ▶❚❚ or Back: stop':
      "OK: schermo intero  ·  ▶❚❚ o Indietro: ferma",
  'Still looking for channels…': "Ricerca dei canali in corso…",
  'No channel found for this game': "Nessun canale trovato per questa partita",
  'On {matches} channel{s}': "Canali: {matches}",
  'Pick the channel': "Scegli il canale",
  'Choose a different channel': "Scegli un altro canale",
  'Search your channels — it can be remembered for this game or team':
      "Cerca tra i tuoi canali; la scelta può essere ricordata per questa partita o squadra",
  'Forget my pick': "Dimentica la mia scelta",
  'Go back to the automatic match': "Torna alla scelta automatica",
  'Remember this channel?': "Ricordare questo canale?",
  'Just this game': "Solo questa partita",
  'Best for channels named after one game':
      "Ideale per canali col nome di una partita",
  'Always for the {shortName}': "Sempre per {shortName}",
  'Best for a regular channel, like a regional network':
      "Ideale per un canale fisso, come una rete regionale",
  'Leagues': "Campionati",
  'Save': "Salva",
  'Pick the channel for {title}': "Scegli il canale per {title}",
  'Search channels': "Cerca canali",
  'No channels match "{query}"': "Nessun canale corrisponde a «{query}»",
  '{results}{p} channels': "{results}{p} canali",
  '{group} · Now: {now}': "{group} · Ora: {now}",
  'Preseason': "Precampionato",
  'Pick a league above, then hold OK on a team to follow it. Back returns to My Teams.':
      "Scegli un campionato in alto, poi tieni premuto OK su una squadra per seguirla. Indietro torna a Le mie squadre.",
  'Standings could not be loaded. Check the connection.':
      "Impossibile caricare la classifica. Controlla la connessione.",
  'switch conference': "cambia conference",
  'switch table': "cambia tabella",
  'Hold OK on a team to follow it (My Teams)':
      "Tieni premuto OK su una squadra per seguirla (Le mie squadre)",
  'Your pick': "La tua scelta",
  'Found by its name': "Trovato dal nome",
  'Found in the guide': "Trovato nella guida",
  'National broadcast': "Trasmissione nazionale",
  'Some scores could not be loaded. Check the connection.':
      "Alcuni risultati non sono stati caricati. Controlla la connessione.",
  'Unfollow': "Non seguire più",
  'Follow': "Segui",
  'Remove from My Teams': "Rimuovi da Le mie squadre",
  'Add to My Teams — their games show first in {tab}':
      "Aggiungi a Le mie squadre: le loro partite appaiono per prime in {tab}",
  // Results (W/L/D = won/lost/draw) and standings columns.
  'W': "V",
  'L': "P",
  'D': "N",
  'T': "N",
  'GP': "G",
  'GD': "DR",
  'PTS': "PT",
  'OTL': "PS",
  'DIFF': "DIFF",
  'STRK': "SERIE",
  'L10': "ULT10",
  'REC': "V-P",
  'PF': "PF",
  'PA': "PS",
  'HOME': "CASA",
  'AWAY': "TRASF",
  'PCT': "PCT",
  'GB': "DIST",

  // ── TV home ──────────────────────────────────────────────────────────
  'TV': "TV",
  'Favorites': "Preferiti",
  'Favourites': "Preferiti",
  'Remove from Favourites': "Rimuovi dai preferiti",
  'Add to Favourites': "Aggiungi ai preferiti",
  'Cancel Hide': "Annulla nascondi",
  'Hide Group': "Nascondi gruppo",
  'Move Up / Down': "Sposta su / giù",
  'Move to Top': "Sposta in cima",
  'Unhide this channel': "Mostra di nuovo il canale",
  'Hide this channel': "Nascondi questo canale",
  'Double': "Doppio",
  'for groups': "per i gruppi",
  'Exit and free up this login?': "Uscire e liberare questo account?",
  'This disconnects your login here so it can be used on another device, then fully closes iptv-app. Your channels/movies will need to reload next time you open it.':
      "Disconnette qui il tuo account, così può essere usato su un altro dispositivo, poi chiude del tutto iptv-app. Canali e film dovranno ricaricarsi alla prossima apertura.",
  'Exit': "Esci",
  'Exit {appName}?': "Uscire da {appName}?",
  'Are you sure you want to exit {appName}?':
      "Vuoi davvero uscire da {appName}?",
  'Stay': "Resta",
  'History': "Cronologia",
  'No channels watched yet.': "Nessun canale guardato finora.",
  'Update Content': "Agg. contenuti",
  'Minimize': "Riduci a icona",
  'Close': "Chiudi",
  'Disable and exit': "Disattiva ed esci",
  'Long-press a group elsewhere to favorite the whole thing.':
      "Tieni premuto OK su un gruppo altrove per aggiungerlo tutto ai preferiti.",
  'Nothing playing': "Nessuna riproduzione",
  'Click to resume': "Clicca per riprendere",
  'Filter channels in this group...': "Filtra i canali del gruppo…",
  'Close filter': "Chiudi filtro",
  'Hidden — find it again in Settings > Playlist Manager > Hidden Channels':
      "Nascosto: lo ritrovi in Impostazioni > Gestione liste > Canali nascosti",
  'Unhidden': "Di nuovo visibile",
  'No favorited movies or TV shows yet.\nHold Select on a poster to add one.':
      "Ancora nessun film o serie nei preferiti.\nTieni premuto OK su una locandina per aggiungerne uno.",
  'No favorited movies yet.': "Ancora nessun film nei preferiti.",
  'No favorited TV shows yet.': "Ancora nessuna serie nei preferiti.",
  'No favorite channels yet — press Down while watching one to add it.':
      "Ancora nessun canale preferito: premi Giù mentre ne guardi uno per aggiungerlo.",
  'Updating…': "Aggiornamento…",
  'No program data': "Nessun palinsesto",
  'No program data available': "Palinsesto non disponibile",
  'Next: {title} ({p})': "Dopo: {title} ({p})",
  'Focus a program to see details':
      "Seleziona un programma per vedere i dettagli",
  'Space': "Spazio",
  'Loading EPG…': "Caricamento guida…",

  // ── Welcome ──────────────────────────────────────────────────────────
  'Hey beautiful Human,': "Ciao, splendido umano,",
  'Hey beautiful Human': "Ciao, splendido umano",
  'Welcome to iptv-app': "Benvenuto in iptv-app",
  'Add your first playlist?': "Aggiungere la tua prima lista?",
  'Add a playlist to kick things off, or skip for now if you just want to browse and discover the app without content.':
      "Aggiungi una lista per cominciare, oppure salta per ora se vuoi solo esplorare l'app senza contenuti.",

  // ── Add playlist ─────────────────────────────────────────────────────
  'Add Playlist': "Aggiungi lista",
  'Paste some text first.': "Prima incolla del testo.",
  "Couldn't find anything usable in that text.":
      "Niente di utilizzabile in quel testo.",
  'Received from your phone — check the details, then press Add Playlist.':
      "Ricevuto dal telefono: controlla i dati, poi premi «Aggiungi lista».",
  'Scan the code with your phone and send the form first.':
      "Prima scansiona il codice col telefono e invia il modulo.",
  'Playlist name is required.': "Il nome della lista è obbligatorio.",
  'Server, username, and password are all required.':
      "Server, nome utente e password sono obbligatori.",
  'M3U playlist URL is required.': "L'URL della lista M3U è obbligatorio.",
  'Playlist updated.': "Lista aggiornata.",
  'Playlist added.': "Lista aggiunta.",
  'Download content': "Scarica contenuti",
  'This provider has a large catalog. Download everything in the background, or choose which groups to include first?':
      "Questo provider ha un catalogo grande. Scaricare tutto in background o scegliere prima quali gruppi includere?",
  'Choose Groups First': "Scegli i gruppi",
  'Download All': "Scarica tutto",
  'Edit Playlist': "Modifica lista",
  'Playlist source': "Origine della lista",
  'M3U URL': "URL M3U",
  'Xtream Codes': "Xtream Codes",
  'Smart Add': "Aggiunta smart",
  'From phone': "Dal telefono",
  'Playlist name': "Nome della lista",
  'Name': "Nome",
  'e.g. My Provider': "es. Il mio provider",
  'M3U Playlist URL': "URL della lista M3U",
  'EPG (XMLTV) URL': "URL della guida (XMLTV)",
  'Paste the message your provider sent you — we\'ll pull out the server, username, and password.':
      "Incolla il messaggio che ti ha mandato il provider: ne ricaviamo server, nome utente e password.",
  'Paste provider message': "Incolla messaggio del provider",
  'Parse': "Analizza",
  'Confirm the server': "Conferma il server",
  'No server URL found in that text — enter it below.':
      "Nessun URL del server in quel testo: inseriscilo qui sotto.",
  'Server URL (e.g. http://host:port)':
      "URL del server (es. http://host:porta)",
  'Username': "Nome utente",
  'Password': "Password",
  'Custom EPG (XMLTV) URL — optional':
      "URL guida personalizzata (XMLTV) — facoltativo",
  'Leave blank to use the panel\'s own xmltv.php. Set this if your provider\'s EPG is empty or unreliable (e.g. a third-party feed like EPGgenius) — it only fills in a channel if that feed\'s ids match this panel\'s.':
      "Lascia vuoto per usare l'xmltv.php del pannello. Compilalo se la guida del tuo provider è vuota o poco affidabile (es. una fonte esterna come EPGgenius); un canale viene compilato solo se gli ID di quella fonte coincidono con quelli del pannello.",
  'Paste different text': "Incolla un altro testo",
  'Status': "Stato",
  'Failed to add playlist: {p}': "Impossibile aggiungere la lista: {p}",
  'Save Changes': "Salva modifiche",
  'Fill in the form on the left, then press {p} above.':
      "Compila il modulo a sinistra, poi premi «{p}» in alto.",
  'Unexpected Xtream API response': "Risposta inattesa dell'API Xtream",
  'Invalid Xtream username/password':
      "Nome utente o password Xtream non validi",
  'Xtream account is not active (status: {status})':
      "L'account Xtream non è attivo (stato: {status})",

  // ── Phone pairing ────────────────────────────────────────────────────
  'Code expired': "Codice scaduto",
  'Add from your phone': "Aggiungi dal telefono",
  'Typing a long password with a remote is painful. Scan this code with your phone camera and fill in the form there — it appears here for you to check and add.':
      "Scrivere una password lunga col telecomando è una fatica. Scansiona questo codice con la fotocamera del telefono e compila lì il modulo: comparirà qui per controllarlo e aggiungerlo.",
  'Scan with your phone (mobile data is fine).':
      "Scansiona col telefono (vanno bene anche i dati mobili).",
  'Connect your phone to the same Wi-Fi as this TV, then scan.':
      "Collega il telefono allo stesso Wi-Fi di questa TV, poi scansiona.",
  'Fill in the form and tap Send to TV.':
      "Compila il modulo e tocca «Send to TV».",
  'Check the details here, then press Add Playlist.':
      "Controlla i dati qui, poi premi «Aggiungi lista».",
  'Waiting for your phone…': "In attesa del telefono…",
  'Or open on the phone:': "Oppure apri sul telefono:",
  'Your details are encrypted on the phone; the relay only passes along scrambled data and deletes it.':
      "I tuoi dati vengono cifrati sul telefono; il relay inoltra solo dati cifrati e poi li cancella.",
  'New code': "Nuovo codice",
  'Phone on this Wi-Fi? Use the Wi-Fi code':
      "Telefono su questo Wi-Fi? Usa il codice Wi-Fi",
  'Phone not on this Wi-Fi? Use the other code':
      "Telefono non su questo Wi-Fi? Usa l'altro codice",

  // ── Channel linking / EPG matching ───────────────────────────────────
  'Add and enable a second playlist first — a link connects a channel on one playlist to its equivalent on another.':
      "Prima aggiungi e attiva una seconda lista: un collegamento unisce un canale di una lista al suo equivalente in un'altra.",
  'Auto-Pair Channels': "Abbina auto.",
  'Unpair Channels': "Separa canali",
  'Reviewing {reviewFilter} auto-paired channel{s} — type to search all instead':
      "Revisione dei canali abbinati auto. ({reviewFilter}): scrivi per cercare in tutti",
  'Search your channels': "Cerca tra i tuoi canali",
  'Not linked': "Non collegato",
  'Linked channel no longer available':
      "Il canale collegato non è più disponibile",
  'Linked to {p}: {name}': "Collegato a {p}: {name}",
  'Clear link': "Rimuovi collegamento",
  'Link "{name}"': "Collega «{name}»",
  'Search other playlists\' channels': "Cerca tra i canali delle altre liste",
  'No matches.': "Nessuna corrispondenza.",
  'No EPG feed has been loaded yet this session — run "Update EPG Now" first so there\'s a channel directory to match against.':
      "Nessuna guida caricata in questa sessione: esegui prima «Agg. guida» per avere un elenco di canali.",
  'No EPG feed has been loaded yet this session — run "Update EPG Now" above first so there\'s a channel directory to search.':
      "Nessuna guida caricata in questa sessione: esegui prima «Agg. guida» (in alto) per avere un elenco di canali.",
  'Assigned: {p}': "Assegnato: {p}",
  'Matched automatically': "Abbinato automaticamente",
  'Clear assignment': "Rimuovi assegnazione",
  'Assign "{channelName}"': "Assegna «{channelName}»",
  'Search the EPG feed\'s channels': "Cerca tra i canali della guida",
  'No EPG feed has been loaded yet this app session — go back and run "Update EPG Now" first.':
      "Nessuna guida caricata in questa sessione: torna indietro ed esegui prima «Agg. guida».",
  'Now: {title}': "Ora: {title}",
  'No current program data': "Nessun programma in corso",
  'Channels are pairing, please wait…':
      "Abbinamento dei canali in corso, attendi…",
  'No new matches found — anything still unmatched needs a manual pick.':
      "Nessuna nuova corrispondenza: il resto va scelto a mano.",
  'Paired {paired} channel{s} automatically.':
      "Canali abbinati automaticamente: {paired}.",
  'Review': "Rivedi",
  'Continue': "Continua",
  'Nothing was auto-paired — there\'s nothing to undo.':
      "Nessun abbinamento automatico: niente da annullare.",
  'Undo {autoPairedCount} automatic pairing{s}? Anything you\'ve set by hand is kept.':
      "Annullare gli abbinamenti automatici ({autoPairedCount})? Ciò che hai impostato a mano resta.",
  'Unpair': "Separa",

  // ── Check for updates ────────────────────────────────────────────────
  'Couldn\'t open the download link.':
      "Impossibile aprire il link di download.",
  'Allow installing updates': "Consenti l'installazione degli aggiornamenti",
  'Android needs one-time permission for iptv-app to install an update it downloaded. The next screen is Android\'s own settings — turn the toggle on, then come back here and press Install again.':
      "Android richiede un permesso una tantum perché iptv-app installi un aggiornamento scaricato. La schermata successiva è nelle impostazioni di Android: attiva l'opzione, poi torna qui e premi di nuovo Installa.",
  'Check for Updates': "Cerca aggiornamenti",
  'Current version: —': "Versione attuale: —",
  'Current version: {currentVersion}': "Versione attuale: {currentVersion}",
  'Checking...': "Verifica…",
  'You\'re on the latest version.': "Hai l'ultima versione.",
  'Check Again': "Ricontrolla",
  'Version {version} is available': "È disponibile la versione {version}",
  'Open Download Page': "Apri pagina di download",
  'Opens in your browser — unzip the download and run the application to update, replacing the old folder.':
      "Si apre nel browser: estrai il file scaricato e avvia the application per aggiornare, sostituendo la cartella precedente.",
  'Download & Install': "Scarica e installa",
  'Downloading update... {p}%': "Download aggiornamento… {p}%",
  'Download complete.': "Download completato.",
  'Install': "Installa",
  'Android will ask you to confirm the install — that\'s normal, not every app can skip it.':
      "Android ti chiederà di confermare l'installazione: è normale, non tutte le app possono saltare questo passaggio.",
  'Something went wrong: {p}': "Qualcosa è andato storto: {p}",
  'unknown error': "errore sconosciuto",
  'Try Again': "Riprova",
  'GitHub is temporarily rate-limiting update checks from this network — try again in about {n} minute.':
      "GitHub sta limitando temporaneamente i controlli da questa rete: riprova tra circa {n} minuto.",
  'GitHub is temporarily rate-limiting update checks from this network — try again in about {n} minutes.':
      "GitHub sta limitando temporaneamente i controlli da questa rete: riprova tra circa {n} minuti.",
  'GitHub is temporarily rate-limiting update checks from this network — try again shortly.':
      "GitHub sta limitando temporaneamente i controlli da questa rete: riprova tra poco.",

  // ── EPG settings ─────────────────────────────────────────────────────
  'No EPG URL set yet — add a playlist first.':
      "Nessun URL della guida: prima aggiungi una lista.",
  'Cache cleared.': "Cache svuotata.",
  'EPG': "Guida (EPG)",
  'General': "Generale",
  'EPG Matching': "Abbin. guida",
  'Channel Pairing': "Abbin. canali",
  'Auto-refresh interval': "Intervallo di agg. automatico",
  '{p} hours': "{p} ore",
  'EPG never updated': "Guida mai aggiornata",
  'EPG last updated: {p}': "Ultimo agg. della guida: {p}",
  'Update EPG Now': "Agg. guida",
  'Clear Cache': "Svuota cache",
  'Clears the cached EPG and catalog data — playlist source, favorites, and group visibility are kept.':
      "Svuota la guida e il catalogo in cache; origine delle liste, preferiti e visibilità dei gruppi restano.",
  'Fixes a channel with no program data by manually assigning it to an entry in the loaded EPG feed — useful when a provider\'s own id doesn\'t match a third-party source.':
      "Sistema un canale senza palinsesto assegnandolo a mano a una voce della guida caricata; utile quando l'ID del provider non coincide con una fonte esterna.",
  'Links a channel on one playlist to its equivalent on another. If a live channel fails to load, or you switch to it yourself from the player, playback can fall back to the paired channel on the other playlist instead.':
      "Collega un canale di una lista al suo equivalente in un'altra. Se un canale in diretta non si carica, o se cambi tu dal lettore, la riproduzione può passare al canale abbinato dell'altra lista.",

  // ── General settings ─────────────────────────────────────────────────
  'Clear search & channel history?':
      "Cancellare la cronologia di ricerche e canali?",
  'Removes your recent searches and the History list of live channels.':
      "Rimuove le ricerche recenti e la cronologia dei canali in diretta.",
  'Search and channel history cleared.':
      "Cronologia di ricerche e canali cancellata.",
  'Clear Movies & TV Shows history?':
      "Cancellare la cronologia di film e serie?",
  'Removes Continue Watching and the saved progress of every movie and episode.':
      "Rimuove Continua a guardare e i progressi salvati di ogni film ed episodio.",
  'Movies & TV Shows history cleared.':
      "Cronologia di film e serie cancellata.",
  'Language': "Lingua",
  'Follows the device language': "Segue la lingua del dispositivo",
  'Automatic': "Automatica",
  'Startup': "Avvio",
  'Resume last channel in full screen':
      "Riprendi l'ultimo canale a schermo intero",
  'Opens the last live channel full screen after the splash.':
      "Apre l'ultimo canale in diretta a schermo intero dopo la schermata iniziale.",
  'Resume last channel with the guide open':
      "Riprendi l'ultimo canale con la guida aperta",
  'Plays the last live channel in the small preview, with the channel list.':
      "Riproduce l'ultimo canale in diretta nella piccola anteprima, con l'elenco dei canali.",
  'Both off: nothing plays at startup (a "Hold > to resume" reminder instead).':
      "Entrambi disattivati: all'avvio non parte nulla (al suo posto un promemoria «Tieni premuto > per riprendere»).",
  'Tabs': "Schede",
  'Hide Movies and TV Shows': "Nascondi Film e Serie TV",
  'Removes both tabs and their search results, e.g. if you watch movies and shows elsewhere.':
      "Rimuove le due schede e i relativi risultati di ricerca, ad es. se guardi film e serie altrove.",
  'Favorite channels are in the TV tab, under Favourites.':
      "I canali preferiti sono nella scheda TV, sotto Preferiti.",
  'Show the Multiview tip': "Mostra il consiglio Multivista",
  'The connections reminder shown when opening Multiview.':
      "Il promemoria sulle connessioni all'apertura della Multivista.",
  'Resume reminder': "Promemoria di ripresa",
  'Show the "Hold > to resume" reminder':
      "Mostra il promemoria «Tieni premuto > per riprendere»",
  'The pill at the bottom while a channel plays in the background. Off: hidden.':
      "La pillola in basso mentre un canale è in riproduzione in background. Disattivato: nascosta.",
  'The pill at the bottom while a channel plays in the background. Off: hidden — holding Right still resumes.':
      "La pillola in basso mentre un canale è in riproduzione in background. Disattivato: nascosta; tenere premuto Destra riprende comunque.",
  'Clear search & channel history': "Cancella cronologia di ricerche e canali",
  'Recent searches and the live channel History':
      "Ricerche recenti e cronologia dei canali in diretta",
  'Clear Movies & TV Shows history': "Cancella cronologia di film e serie",
  'Continue Watching and saved progress':
      "«Continua a guardare» e progressi salvati",

  // ── Group management / hidden channels ───────────────────────────────
  'Leave group selection?': "Uscire dalla selezione dei gruppi?",
  'Your show/hide choices are saved, and anything still visible will start downloading — same as pressing Done.':
      "Le tue scelte mostra/nascondi vengono salvate e tutto ciò che è visibile inizierà a scaricarsi, come premendo Fatto.",
  'Leave': "Esci",
  'Save playlist?': "Salvare la lista?",
  'Your playlist will be saved with the selected groups. You can always add or remove groups later in Settings > Group Management.':
      "La lista sarà salvata con i gruppi scelti. Potrai sempre aggiungere o togliere gruppi in Impostazioni > Gestione gruppi.",
  'Confirm': "Conferma",
  'Group Management': "Gestione gruppi",
  'Done': "Fatto",
  'If you are done selecting your groups, press Confirm below.\n\nIf you are not done yet, press Left to go back to your categories.':
      "Se hai finito di scegliere i gruppi, premi Conferma qui sotto.\n\nAltrimenti premi Sinistra per tornare alle categorie.",
  'No categories yet — load a playlist first.':
      "Nessuna categoria: prima carica una lista.",
  'Show All': "Mostra tutto",
  'Hide All': "Nascondi tutto",
  'Hidden channels': "Canali nascosti",
  'No channels are individually hidden. Hide one from its row in the Live TV list.':
      "Nessun canale nascosto singolarmente. Nascondine uno dalla sua riga nell'elenco TV in diretta.",
  'Unhide': "Mostra",
  'Show group': "Mostra gruppo",
  'Hide group': "Nascondi gruppo",

  // ── Playlist manager / priority ──────────────────────────────────────
  'Playlist Manager': "Gestione liste",
  'Playlist Priority': "Priorità liste",
  'Which playlist\'s groups show first, per tab':
      "Quale lista mostra prima i suoi gruppi, per scheda",
  'No playlists yet — tap "Add Playlist" above to get started.':
      "Ancora nessuna lista: premi «Aggiungi lista» in alto per iniziare.",
  'Delete playlist?': "Eliminare la lista?",
  'This removes "{name}"\'s login and cached catalog from this device. Its favorited channels/movies stay in your shared Favorites list, but will no longer play unless you add this playlist back.':
      "Rimuove da questo dispositivo l'account e il catalogo in cache di «{name}». I suoi canali e film preferiti restano nei Preferiti, ma non si riprodurranno finché non aggiungi di nuovo questa lista.",
  'Delete': "Elimina",
  'Add backup server': "Aggiungi server di riserva",
  'The full address, exactly like the main one — for example http://backup.example.com:8080':
      "L'indirizzo completo, come quello principale; ad esempio http://backup.example.com:8080",
  'Server address': "Indirizzo del server",
  'Add': "Aggiungi",
  'Edit login': "Modifica account",
  'Delete playlist': "Elimina lista",
  'This Playlist': "Questa lista",
  'Playlist enabled': "Lista attiva",
  'Frees up this account\'s stream slot for another device — stops playback here immediately, keeps everything else intact.':
      "Libera la connessione di questo account per un altro dispositivo: ferma subito la riproduzione qui e lascia intatto tutto il resto.",
  'Login Details': "Dati dell'account",
  'Server': "Server",
  'Expires': "Scadenza",
  'Max connections': "Connessioni max.",
  'Backup Servers': "Server di riserva",
  'None yet. If your provider gave you more than one server address for this same account, add them here and this playlist will try them in order whenever the main one can\'t be reached.':
      "Nessuno. Se il provider ti ha dato più indirizzi di server per questo stesso account, aggiungili qui: la lista li proverà in ordine quando quello principale non risponde.",
  'Same username and password as above — only the address differs. Tried in order, a few seconds apart, and whichever answers is used first next time.':
      "Stessi nome utente e password di sopra; cambia solo l'indirizzo. Vengono provati in ordine, a pochi secondi l'uno dall'altro, e quello che risponde viene usato per primo la volta successiva.",
  'Content Overview': "Panoramica contenuti",
  'Not loaded yet.': "Non ancora caricato.",
  '{p} live channels · {p2} movie categories · {p3} TV show categories':
      "{p} canali in diretta · {p2} categorie di film · {p3} categorie di serie",
  '{p} live · {p2} movies · {p3} TV shows':
      "{p} in diretta · {p2} film · {p3} serie",
  'Last updated: {p}': "Ultimo agg.: {p}",
  'Added: {p}': "Aggiunta: {p}",
  'Hidden Channels': "Canali nascosti",
  'Hide a group here and it\'s excluded from the background download too, not just the browse tabs.':
      "Un gruppo nascosto qui viene escluso anche dal download in background, non solo dalle schede.",
  'Full Catalog Sync': "Sincronizzazione completa del catalogo",
  'Update content every': "Aggiorna i contenuti ogni",
  '1 day': "1 giorno",
  '{d} days': "{d} giorni",
  'A stale sync prompts "Update content now?" on launch instead of running automatically.':
      "Una sincronizzazione vecchia mostra «Aggiornare i contenuti adesso?» all'avvio invece di partire da sola.",
  'in use': "in uso",
  'Remove {server}': "Rimuovi {server}",
  'Which playlist\'s groups show first — set independently for each tab below.':
      "Quale lista mostra prima i suoi gruppi; si imposta separatamente per ogni scheda qui sotto.",
  'Add another enabled playlist to set a priority between them.':
      "Aggiungi un'altra lista attiva per impostare una priorità tra le due.",
  'Live TV order': "Ordine TV in diretta",
  'Movies order': "Ordine film",
  'TV Shows order': "Ordine serie",
  'Move up': "Sposta su",
  'Move down': "Sposta giù",
  'Playlist added': "Lista aggiunta",
  'This playlist is disabled on this device — enable it in Settings > Playlist Manager to watch.':
      "Questa lista è disattivata su questo dispositivo: attivala in Impostazioni > Gestione liste per guardare.",

  // ── Profiles / PIN ───────────────────────────────────────────────────
  'Profiles': "Profili",
  'Add Profile': "Aggiungi profilo",
  'Rename profile': "Rinomina profilo",
  'Delete "{name}"?': "Eliminare «{name}»?",
  'Their favorites, hidden groups, and watch history are deleted too. This can\'t be undone.':
      "Vengono eliminati anche preferiti, gruppi nascosti e cronologia. Non si può annullare.",
  'Switch to another profile before deleting this one':
      "Passa a un altro profilo prima di eliminare questo",
  'Delete profile': "Elimina profilo",
  'This is the active profile': "Questo è il profilo attivo",
  'Switch to this profile': "Passa a questo profilo",
  'Rename': "Rinomina",
  'What this profile can see': "Cosa può vedere questo profilo",
  'Groups — {name}': "Gruppi — {name}",
  'Hidden channels — {name}': "Canali nascosti — {name}",
  'For a child — hides every group, including adult content, by default. A parent unhides specific categories per playlist afterward in Group Management. A PIN is required to switch away from this profile or to open Settings while it\'s active.':
      "Per un bambino: nasconde tutti i gruppi per impostazione predefinita, compresi i contenuti per adulti. Poi un genitore mostra categorie specifiche per ogni lista in Gestione gruppi. Serve un PIN per uscire da questo profilo o aprire le Impostazioni mentre è attivo.",
  'Create': "Crea",
  'Incorrect PIN': "PIN errato",
  "PINs didn't match — try again": "I PIN non coincidono: riprova",
  'Enter PIN': "Inserisci il PIN",
  'Confirm PIN': "Conferma il PIN",
  'Set a PIN': "Imposta un PIN",
  'Too many attempts — try again in {p}s':
      "Troppi tentativi: riprova tra {p} s",

  // ── Settings menu ────────────────────────────────────────────────────
  'M3U URL or Xtream Codes login': "URL M3U o account Xtream Codes",
  'Every playlist: login, groups, enable/disable':
      "Tutte le liste: account, gruppi, attiva/disattiva",
  'Separate favorites, history & hidden groups per viewer':
      "Preferiti, cronologia e gruppi nascosti separati per persona",
  'Language and history': "Lingua e cronologia",
  'Language, startup, Multiview and history':
      "Lingua, avvio, Multivista e cronologia",
  'Theme': "Tema",
  'Clock, accent color, layout': "Orologio, colore, layout",
  'Auto-refresh, channel matching & pairing, clear cache':
      "Agg. automatico, abbinamento canali, svuota cache",
  'TMDB (Release Dates)': "TMDB (date di uscita)",
  'Optional key for sorting by real release date':
      "Chiave facoltativa per ordinare per data di uscita reale",
  'Download and install the latest release':
      "Scarica e installa l'ultima versione",
  'Version —': "Versione —",
  'Version {version}': "Versione {version}",

  // ── Theme ────────────────────────────────────────────────────────────
  'Show clock': "Mostra orologio",
  'Displays the current time in the top bar':
      "Mostra l'ora nella barra in alto",
  'Theme color': "Colore del tema",
  'Auto picks phone vs TV layout by screen size — force one if your box isn\'t detected correctly.':
      "«Auto» sceglie il layout telefono o TV in base allo schermo; forzane uno se il tuo box non viene riconosciuto bene.",
  'Live TV guide': "Guida TV in diretta",
  'Timeline shows every channel at once, on a scrollable schedule grid, instead of one channel\'s now/next at a time.':
      "«Palinsesto» mostra tutti i canali insieme in una griglia scorrevole, invece dell'ora/dopo di un canale alla volta.",
  'Full-screen video behind the guide':
      "Video a schermo intero dietro la guida",
  'The live channel fills the screen behind a see-through guide showing 3 rows':
      "Il canale in diretta riempie lo schermo dietro una guida trasparente a 3 righe",
  'Auto': "Auto",
  'Phone': "Telefono",
  'Timeline': "Palinsesto",
  'Platinum': "Platino",
  'Rosé': "Rosé",
  'Neon Purple': "Viola neon",
  'Neon Green': "Verde neon",
  'Habs': "Habs",
  'Dark / Gold': "Nero / Oro",

  // ── TMDB ─────────────────────────────────────────────────────────────
  'Cleared — TMDB sorting is now off':
      "Cancellata: l'ordinamento TMDB è disattivato",
  'Saved — key verified with TMDB ✓': "Salvata: chiave verificata con TMDB ✓",
  'Saved, but TMDB rejected this key — double-check it\'s correct':
      "Salvata, ma TMDB ha rifiutato la chiave: controlla che sia giusta",
  'What\'s New refreshed from TMDB': "Novità aggiornate da TMDB",
  'TMDB (The Movie Database) is a free, independent movie and TV database — not your IPTV provider. Adding your own free TMDB key lets iptv-app look up a title\'s actual real-world release date, which powers two things: a "TMDB" sort option on any group\'s "Expand catalog" screen, and a more accurate "What\'s New" row (ordered by real release date instead of just when your provider added the title).':
      "TMDB (The Movie Database) è un database di film e serie gratuito e indipendente, non il tuo provider IPTV. Con una tua chiave TMDB gratuita, iptv-app trova la data di uscita reale di un titolo, utile per due cose: un ordinamento «TMDB» nella schermata «Catalogo completo» di ogni gruppo e una riga «Novità» più precisa (ordinata per data di uscita reale invece che per quando il provider ha aggiunto il titolo).",
  'This is completely optional and free — iptv-app works 100% without it. Without a key, sorting just falls back to whenever your provider added or updated each title, which is still available and works fine on its own.':
      "È del tutto facoltativa e gratuita: iptv-app funziona al 100% anche senza. Senza chiave, l'ordinamento usa la data in cui il provider ha aggiunto o aggiornato ogni titolo, che funziona bene comunque.",
  'To get one: create a free account at themoviedb.org, then generate an API key under Settings > API (choose "Personal use" when asked) and paste it below. iptv-app never collects or shares it — it\'s stored only on this device.':
      "Per ottenerla: crea un account gratuito su themoviedb.org, genera una chiave API in Settings > API (scegli «Personal use» quando richiesto) e incollala qui sotto. iptv-app non la raccoglie né la condivide mai: resta solo su questo dispositivo.",
  'TMDB API Key': "Chiave API TMDB",
  'What\'s New only re-checks TMDB about once a week on its own. Use this to force it right now instead of waiting — useful right after saving a key for the first time.':
      "Novità ricontrolla TMDB da sola circa una volta a settimana. Usa questo per forzarla subito; utile appena salvata una chiave per la prima volta.",
  'Refresh What\'s New Now': "Aggiorna Novità ora",
  'This product uses the TMDB API but is not endorsed or certified by TMDB.':
      "Questo prodotto usa l'API TMDB ma non è approvato né certificato da TMDB.",

  // ── Loading phases / connection ──────────────────────────────────────
  'No Title': "Senza titolo",
  'Reconnecting...': "Riconnessione…",
  'Trying to reconnect on backup servers ({p}/{candidates})...':
      "Tentativo di riconnessione ai server di riserva ({p}/{candidates})…",
  'Finding live channels... ({p} found)':
      "Ricerca canali in diretta… ({p} trovati)",
  'Finding movies... ({p} found)': "Ricerca film… ({p} trovati)",
  'Finding TV shows... ({p} found)': "Ricerca serie… ({p} trovate)",
  'Connecting to {label} ({p}/{candidates})...':
      "Connessione a {label} ({p}/{candidates})…",
  'Connected to {label}': "Connesso a {label}",
  'Connecting to {label} ({p}/{candidates})... failed':
      "Connessione a {label} ({p}/{candidates})… non riuscita",
  'Finding live channels...': "Ricerca canali in diretta…",
  'Finding live channels... ({loadedLive} found)':
      "Ricerca canali in diretta… ({loadedLive} trovati)",
  'Finding movie categories...': "Ricerca categorie di film…",
  'Finding movies... ({vodCategories} categories found)':
      "Ricerca film… ({vodCategories} categorie trovate)",
  'Finding TV show categories...': "Ricerca categorie di serie…",
  'Finding TV shows... ({seriesCategories} categories found)':
      "Ricerca serie… ({seriesCategories} categorie trovate)",
  'Loading full catalog in the background — {p}':
      "Caricamento del catalogo completo in background — {p}",
  'Ready': "Pronto",
  '{done}/{total} categories': "{done}/{total} categorie",

  'Failed to load EPG (HTTP {code})':
      "Impossibile caricare la guida (HTTP {code})",
  'Failed to load playlist from {host} (HTTP {code})':
      "Impossibile caricare la lista da {host} (HTTP {code})",
  'Xtream request to {server} failed: {action} (HTTP {code})':
      "Richiesta Xtream a {server} non riuscita: {action} (HTTP {code})",
  'Main': "Principale",
  '{h}h ': "{h} h ",

  // ── Small widgets ────────────────────────────────────────────────────
  'Unpin': "Rimuovi dai preferiti",
  'Pin as favorite': "Fissa nei preferiti",
  'Next: {p}': "Dopo: {p}",
  'NOW: {title} ({p}-{p2})': "ORA: {title} ({p}-{p2})",
  'NEXT: {title} ({p})': "DOPO: {title} ({p})",
  'Hold ': "Tieni premuto ",
  ' to resume': " per riprendere",
  'Expand sidebar': "Espandi pannello",
  'Collapse sidebar': "Comprimi pannello",
  'Pinned channels': "Canali fissati",
  'League manager': "Gestione campionati",
  'Your leagues': "I tuoi campionati",
  'League bank': "Archivio campionati",
  'Every league is added.': "Tutti i campionati sono aggiunti.",
  'Added · hold to send back': "Aggiunto · tieni premuto per rimetterlo",
  '{name} is back in the league bank':
      "{name} è tornato nell'archivio campionati",
  'England': "Inghilterra",
  'Spain': "Spagna",
  'Germany': "Germania",
  'Italy': "Italia",
  'France': "Francia",
  'Europe': "Europa",
  'Cups': "Coppe",
  'Americas': "Americhe",
  'World': "Mondo",
  'Women': "Femminile",
  'Basketball': "Basket",
  'Hockey': "Hockey",
  'Baseball': "Baseball",
  'Other': "Altri",
  'Golf': "Golf",
  'Tennis': "Tennis",
  'Fighting': "Combattimento",
  'Motorsport': "Motori",
  'Always for {name}': "Sempre per {name}",
  'Best for a channel that carries the whole series':
      "Ideale per un canale che trasmette tutta la serie",
  'Next game: {date}': "Prossima partita: {date}",
  'No upcoming games listed yet for this league.':
      "Ancora nessuna partita in programma per questo campionato.",
  'Transfer to another device': "Trasferisci su un altro dispositivo",
  'Copy playlists, favorites and settings over Wi-Fi':
      "Copia liste, preferiti e impostazioni via Wi-Fi",
  'Copies your playlists, favorites, hidden groups, profiles, watch progress and settings to another device. On the same Wi-Fi it goes straight across; anywhere else it goes through an encrypted upload only the code can open. Channels, movies and the guide download again on the new device.':
      "Copia liste, preferiti, gruppi nascosti, profili, progressi e impostazioni su un altro dispositivo. Sullo stesso Wi-Fi passa direttamente; altrove passa da un caricamento cifrato che solo il codice può aprire. Canali, film e guida vengono scaricati di nuovo sul nuovo dispositivo.",
  'This setup is too big to upload. Use the same-Wi-Fi transfer instead.':
      "Questa configurazione è troppo grande da caricare. Usa invece il trasferimento sullo stesso Wi-Fi.",
  'Couldn\'t reach the iptv-app transfer server. Check this device\'s internet connection and try again.':
      "Impossibile raggiungere il server di trasferimento iptv-app. Controlla la connessione internet di questo dispositivo e riprova.",
  '{n} hour': "{n} ora",
  '{n} hours': "{n} ore",
  '{n} day': "{n} giorno",
  '{n} days': "{n} giorni",
  'Your setup is encrypted on this device and uploaded. Any device that enters the code can copy it until it expires — even with this device turned off. How long should it stay available?':
      "La configurazione viene cifrata su questo dispositivo e caricata. Qualsiasi dispositivo che inserisce il codice può copiarla fino alla scadenza, anche con questo dispositivo spento. Per quanto tempo deve restare disponibile?",
  'Encrypting and uploading…': "Cifratura e caricamento…",
  'Works on any network until {time}':
      "Funziona su qualsiasi rete fino a: {time}",
  'Anyone with this code can copy your setup, playlist logins included. Changes made after this upload aren\'t in it — upload again to update it.':
      "Chiunque abbia questo codice può copiare la configurazione, credenziali delle liste comprese. Le modifiche fatte dopo questo caricamento non sono incluse: carica di nuovo per aggiornarla.",
  'Upload again': "Carica di nuovo",
  'Delete now': "Elimina ora",
  'Nothing was found for that code. Check it — the upload may also have expired or been deleted.':
      "Non è stato trovato nulla per questo codice. Controllalo: il caricamento potrebbe anche essere scaduto o eliminato.",
  '9 digits on the same Wi-Fi, 16 digits over the internet':
      "9 cifre sullo stesso Wi-Fi, 16 via internet",
  '24-hour clock': "Orologio a 24 ore",
  'Times show as 21:30': "Gli orari appaiono così: 21:30",
  'Times show as 9:30 PM': "Gli orari appaiono così: 9:30 PM",
  'Welcome back, legend':
      "Bentornato, leggenda",
  'No favourites yet. Hold Select on a poster or a group to add one.':
      "Ancora nessun preferito. Tieni premuto OK su una locandina o un gruppo per aggiungerne uno.",
  'Rotate': "Ruota",
  'You have great taste':
      "Hai davvero buon gusto",
  'Looking sharp today':
      "Oggi sei in gran forma",
  'You make this place better':
      "Rendi questo posto migliore",
  'Hey superstar':
      "Ciao, superstar",
  'You deserve this break':
      "Ti meriti questa pausa",
  'You\'re doing amazing':
      "Stai andando alla grande",
  'Hello, wonderful you':
      "Ciao, persona meravigliosa",
  'Smart choice, as always':
      "Ottima scelta, come sempre",
  'You light up the room':
      "Illumini la stanza",
  'Keep shining, you\'ve got this':
      "Continua a brillare, ce la fai",
  'You earned some fun today':
      "Oggi ti sei meritato un po' di svago",
  'The world is better with you in it':
      "Il mondo è migliore con te",
  'Hey champ, welcome in':
      "Ciao campione, benvenuto",
  'Send from this device': "Invia da questo dispositivo",
  'Shows a code to enter on the other device':
      "Mostra un codice da inserire sull'altro dispositivo",
  'Both devices on the same Wi-Fi?':
      "Entrambi i dispositivi sullo stesso Wi-Fi?",
  'Send directly, without uploading': "Invia direttamente, senza caricare",
  'Receive on this device': "Ricevi su questo dispositivo",
  'Replaces this device\'s setup with the other one\'s':
      "Sostituisce la configurazione di questo dispositivo con quella dell'altro",
  'This device isn\'t on a Wi-Fi or wired home network.':
      "Questo dispositivo non è su una rete Wi-Fi o via cavo.",
  'Sent! Finish on the other device.':
      "Inviato! Completa sull'altro dispositivo.",
  'This code has expired. Go back and start again.':
      "Questo codice è scaduto. Torna indietro e ricomincia.",
  'On the other device, open Settings > Transfer to another device > Receive, and enter:':
      "Sull'altro dispositivo, apri Impostazioni > Trasferisci su un altro dispositivo > Ricevi e inserisci:",
  'This device: {address} · the code works once, for 10 minutes':
      "Questo dispositivo: {address} · il codice vale una volta, per 10 minuti",
  'Couldn\'t find the other device. Check the code, and that both devices are on the same Wi-Fi with the code still showing.':
      "Impossibile trovare l'altro dispositivo. Controlla il codice e che entrambi siano sullo stesso Wi-Fi con il codice ancora visibile.",
  'That code isn\'t right. Check it on the other device.':
      "Il codice non è corretto. Controllalo sull'altro dispositivo.",
  'That code has expired or was already used. Start again on the other device.':
      "Il codice è scaduto o è già stato usato. Ricomincia sull'altro dispositivo.",
  'The transfer didn\'t go through. Try again.':
      "Il trasferimento non è riuscito. Riprova.",
  'Transfer complete': "Trasferimento completato",
  'iptv-app will close now. Open it again to load your playlists.':
      "iptv-app ora si chiuderà. Riaprilo per caricare le tue liste.",
  'Enter the code shown on the other device':
      "Inserisci il codice mostrato sull'altro dispositivo",
  'Ready to copy': "Pronto da copiare",
  '{playlists} playlists · {profiles} profiles · {favorites} favorites':
      "Liste: {playlists} · Profili: {profiles} · Preferiti: {favorites}",
  'This replaces the playlists, favorites and settings on this device.':
      "Questo sostituisce liste, preferiti e impostazioni di questo dispositivo.",
  'Replace my data': "Sostituisci i miei dati",
  'Enter the address shown under the code on the other device (This device: …)':
      "Inserisci l'indirizzo mostrato sotto il codice sull'altro dispositivo (Questo dispositivo: …)",
  'Code: {code}': "Codice: {code}",
  'Type the address instead': "Inserisci l'indirizzo",
  '{n} playlist': "{n} lista",
  '{n} playlists': "{n} liste",
  '{n} profile': "{n} profilo",
  '{n} profiles': "{n} profili",
  '{n} favorite': "{n} preferito",
  '{n} favorites': "{n} preferiti",
  'Clear favourites?':
      "Cancellare i preferiti?",
  "Removes every starred item and favourite group from this tab's Favourites.":
      "Rimuove tutti gli elementi con stella e i gruppi preferiti dai Preferiti di questa scheda.",
  'Favourites cleared.':
      "Preferiti cancellati.",
  'Delete watched history?': "Eliminare la cronologia di visione?",
  'Removes the History list of live channels.':
      "Cancella l'elenco Cronologia dei canali in diretta.",
  'Watched history deleted.': "Cronologia di visione eliminata.",
  'NFL RedZone channel': "Canale NFL RedZone",
  // Series detail screen
  'Resume {code}': "Riprendi {code}",
  'Play {code}': "Riproduci {code}",
  '{n} seasons': "{n} stagioni",
  '{n} episodes': "{n} episodi",
  '1 episode': "1 episodio",
  '{m} min': "{m} min",
  '{h} h {m} min': "{h} h {m} min",
  'Episode {n}': "Episodio {n}",
  'Watched': "Visto",
  'More': "Altro",
  'Watching': "In visione",
  'Marked as watched': "Segnato come visto",
  'Marked as unwatched': "Segnato come non visto",
  'Hold to mark as watched': "Tieni premuto per segnare come visto",
  'Hold to mark as unwatched': "Tieni premuto per segnare come non visto",
  'Cast: {names}': "Cast: {names}",
  'Director: {names}': "Regia: {names}",
  'Specials': "Speciali",
  'Movie and TV artwork and data may come from TMDB (The Movie Database).':
      "Le immagini e i dati di film e serie possono provenire da TMDB (The Movie Database).",
  '{appName} {version} is available': "{appName} {version} è disponibile",
  "What's new:": "Novità:",
  'A new version is ready to install.': "Una nuova versione è pronta per l'installazione.",
  'Skip this version': "Salta questa versione",
  'Later': "Più tardi",
  'See all · stats': "Vedi tutto · statistiche",
  'Live games': "Partite in diretta",
  'Click a game for its stats': "Clicca una partita per le sue statistiche",
  'No games are live right now': "Nessuna partita in diretta ora",
  'RED ZONE': "RED ZONE",
  'No channel': "Nessun canale",
  'Watch on {channel}': "Guarda su {channel}",
  'No channel found. Hold OK on the game in {tab} to pick one.': "Nessun canale trovato. Tieni premuto OK sulla partita in {tab} per sceglierne uno.",
  '▲▼ scroll · Back closes': "▲▼ scorri · Indietro chiude",
  'Passing': "Passaggi",
  'Rushing': "Corse",
  'Receiving': "Ricezioni",
  'Defense': "Difesa",
  'Kicking': "Calci",
  'Forwards': "Attaccanti",
  'Defensemen': "Difensori",
  'Goalies': "Portieri",
  'Batting': "Battuta",
  'Pitching': "Lanciatori",
  'Players': "Giocatori",
  'No stats for this game yet.': "Ancora nessuna statistica per questa partita.",
  'Top performers': "Migliori giocatori",
  'Injuries': "Infortuni",
  'Goals': "Gol",
  'pen.': "rig.",
  'Team stats': "Statistiche di squadra",
  'OK = stats · hold OK = channels · ▶❚❚ = watch': "OK = statistiche · tieni premuto OK = canali · ▶❚❚ = guarda",
  '{channel} · full screen': "{channel} · schermo intero",
  // ── Archive tab ──────────────────────────────────────────────────────
  "Add a source": "Aggiungi una fonte",
  "Couldn't load the catalog: {error}": "Impossibile caricare il catalogo: {error}",
  "Couldn't reach that link.": "Impossibile raggiungere quel link.",
  "No playable stream for this title.": "Nessuno stream riproducibile per questo titolo.",
  "No sources yet.": "Ancora nessuna fonte.",
  "None of your sources has TV shows.": "Nessuna delle tue fonti ha serie TV.",
  "None of your sources has movies.": "Nessuna delle tue fonti ha film.",
  "Nothing here yet.": "Ancora niente qui.",
  "Refresh": "Aggiorna",
  "Source link (ends with manifest.json)": "Link della fonte (termina con manifest.json)",
  "That source is already in the list.": "Quella fonte è già nell'elenco.",
  "This source lists no episodes for this show.": "Questa fonte non elenca episodi per questa serie.",
  "iptv-app ships no sources. The titles you open are requested from the source you added; nothing else is shared.": "iptv-app non include fonti. I titoli che apri vengono richiesti alla fonte che hai aggiunto; nient'altro viene condiviso.",
  "Your sources": "Le tue fonti",
  "{n} TV show catalogs": "{n} cataloghi di serie",
  "{n} movie catalogs": "{n} cataloghi di film",
  "Check the link here, then press Add.": "Controlla il link qui, poi premi Aggiungi.",
  "Hide Movies": "Nascondi Film",
  "Hide TV Shows": "Nascondi Serie TV",
  "Paste the link and tap Send to TV.": "Incolla il link e tocca Invia alla TV.",
  "Removes the Movies tab and movie search results.": "Rimuove la scheda Film e i film dai risultati di ricerca.",
  "Removes the TV Shows tab and show search results.": "Rimuove la scheda Serie TV e le serie dai risultati di ricerca.",
  "Typing a long link with a remote is painful. Scan this code with your phone camera and paste the link there — it appears here for you to check and add.": "Digitare un link lungo con il telecomando è faticoso. Scansiona questo codice con la fotocamera del telefono e incolla lì il link — apparirà qui da controllare e aggiungere.",
  // Archive: rows, search, stream picker
  'Popular': 'Popolari',
  'New': 'Novità',
  'Featured': 'In evidenza',
  'Search movies': 'Cerca film',
  'Search TV shows': 'Cerca serie TV',
  'Title': 'Titolo',
  'Searching…': 'Ricerca…',
  'Clear search': 'Cancella ricerca',
  'Results for "{query}"': 'Risultati per «{query}»',
  'No results for "{query}"': 'Nessun risultato per «{query}»',
  'Choose a stream': 'Scegli un flusso',
  'Stream {n}': 'Flusso {n}',
  // Transfer: Archive tab data
  // Media Hub tab (was Extras, before that Archive) + Multiview toggle
  // Trakt & Simkl (trackers_screen.dart, tracker rows)
  'Watch tracking powered by Trakt and Simkl; iptv-app is not affiliated with or endorsed by either.': "Tracciamento della visione fornito da Trakt e Simkl; iptv-app non è affiliato né approvato da nessuno dei due.",
  'Powered by Trakt (trakt.tv) and Simkl (simkl.com).': "Basato su Trakt (trakt.tv) e Simkl (simkl.com).",
  'iptv-app is not affiliated with or endorsed by Trakt or Simkl.': "iptv-app non è affiliato né approvato da Trakt o Simkl.",
  'Trakt & Simkl': 'Trakt e Simkl',
  'Track what you watch, lists in the Media Hub': 'Traccia ciò che guardi, liste nel Media Hub',
  'Connected as {name} — press OK to disconnect': 'Connesso come {name} — premi OK per disconnettere',
  'Not available in this build yet': 'Non ancora disponibile in questa versione',
  'Connect a watch tracker: what you watch in the Media Hub is marked as watched on your account, and your lists show up as Media Hub rows. Nothing is sent unless you connect an account.': 'Collega un servizio di tracciamento: ciò che guardi nel Media Hub viene segnato come visto sul tuo account e le tue liste compaiono come righe nel Media Hub. Non viene inviato nulla se non colleghi un account.',
  'Watchlist and trending rows, scrobbling': 'Righe watchlist e tendenze, scrobbling',
  'Watching and plan-to-watch rows, scrobbling': 'Righe in visione e da vedere, scrobbling',
  'Titles from your lists play through your stream add-ons (Media Hub sources), by IMDb id. Only titles with an IMDb id are reported.': 'I titoli delle tue liste vengono riprodotti tramite i tuoi add-on di flussi (fonti Media Hub), per id IMDb. Vengono segnalati solo i titoli con un id IMDb.',
  '{name} connected.': '{name} collegato.',
  'Disconnect {name}?': 'Disconnettere {name}?',
  'Its rows leave the Media Hub and plays are no longer reported. Your account itself is untouched.': 'Le sue righe escono dal Media Hub e le riproduzioni non vengono più segnalate. Il tuo account non viene modificato.',
  'Disconnect': 'Disconnetti',
  'Couldn\'t reach {name}. Check the connection.': 'Impossibile raggiungere {name}. Controlla la connessione.',
  'The code expired. Try again.': 'Il codice è scaduto. Riprova.',
  'Sign-in was not completed. Try again.': 'L\'accesso non è stato completato. Riprova.',
  'Connect {name}': 'Collega {name}',
  'On your phone or computer, open': 'Sul telefono o sul computer, apri',
  'and enter this code:': 'e inserisci questo codice:',
  'Waiting for you to approve…': 'In attesa della tua approvazione…',
  'Try again': 'Riprova',
  'Trakt watchlist': 'Watchlist Trakt',
  'Trending on Trakt': 'Di tendenza su Trakt',
  'Watching on Simkl': 'In visione su Simkl',
  'Simkl plan to watch': 'Da vedere su Simkl',
  // Multiview picker: Live now / Sports shortcuts
  '{n} channels': '{n} canali',
  'No live games on your channels right now': 'Nessuna partita in diretta sui tuoi canali al momento',
  // Media Hub: Connect Jellyfin / Emby (media_server_screen.dart)
  'Connect Jellyfin / Emby': 'Collega Jellyfin / Emby',
  'User name': 'Nome utente',
  'Connect': 'Collega',
  'Enter the server address and your user name.': 'Inserisci l\'indirizzo del server e il tuo nome utente.',
  'Wrong user name or password.': 'Nome utente o password errati.',
  'This account has no movie or TV library.': 'Questo account non ha librerie di film o serie.',
  'Couldn\'t find a Jellyfin or Emby server at that address.': 'Nessun server Jellyfin o Emby trovato a questo indirizzo.',
  'Sign in to your own Jellyfin or Emby server: its movie and TV libraries show up in the Media Hub. Files play as they are stored on the server (no transcoding).': 'Accedi al tuo server Jellyfin o Emby: le sue librerie di film e serie compaiono nel Media Hub. I file vengono riprodotti così come sono salvati sul server (senza transcodifica).',
  'Your password is only sent to your server. iptv-app keeps the sign-in token the server gives back, not the password.': 'La password viene inviata solo al tuo server. iptv-app conserva il token di accesso restituito dal server, non la password.',
  'Media Hub': 'Media Hub',
  'Media Hub sources': 'Fonti Media Hub',
  'Add-on sources for the Media Hub tab': 'Fonti add-on per la scheda Media Hub',
  'Clear Media Hub?': 'Cancellare il Media Hub?',
  'Clear Media Hub': 'Cancella Media Hub',
  'Media Hub cleared.': 'Media Hub cancellato.',
  'Include Media Hub tab data': 'Includi i dati della scheda Media Hub',
  'Media Hub sources and their watch progress are sent too': 'Vengono inviati anche le fonti Media Hub e i progressi di visione',
  'The other device keeps its own Media Hub sources': 'L\'altro dispositivo mantiene le proprie fonti Media Hub',
  'Add a source to browse films and series. Any source that follows the catalog/stream add-on format works.': 'Aggiungi una fonte per sfogliare film e serie. Funziona qualsiasi fonte che segua il formato add-on catalogo/flusso.',
  'That link isn\'t a Media Hub source (it needs movie or series streams).': 'Quel link non è una fonte Media Hub (servono flussi di film o serie).',
  'Removes every Media Hub source and its saved catalog from this device.': 'Rimuove tutte le fonti Media Hub e il loro catalogo salvato da questo dispositivo.',
  'The Media Hub tab shows films and series from sources you add here. Any source that follows the catalog/stream add-on format works; a source that only offers streams by IMDb id gets its posters and episodes from Cinemeta. Only direct video links are played; torrent links are ignored.': 'La scheda Media Hub mostra film e serie dalle fonti che aggiungi qui. Funziona qualsiasi fonte che segua il formato add-on catalogo/flusso; una fonte che offre solo flussi per id IMDb prende locandine ed episodi da Cinemeta. Si riproducono solo link video diretti; i link torrent vengono ignorati.',
  'Hide Media Hub': 'Nascondi Media Hub',
  'Removes the Media Hub tab.': 'Rimuove la scheda Media Hub.',
  'Hide Multiview': 'Nascondi Multivista',
  'Removes the Multiview row and the player\'s Open in Multiview button.': 'Rimuove la riga Multivista e il pulsante Apri in Multivista del lettore.',
  // Extras genre filter
  'Genre': 'Genere',
  'All genres': 'Tutti i generi',
  'genre.Action': 'Azione',
  'genre.Adventure': 'Avventura',
  'genre.Animation': 'Animazione',
  'genre.Biography': 'Biografico',
  'genre.Comedy': 'Commedia',
  'genre.Crime': 'Crimine',
  'genre.Documentary': 'Documentario',
  'genre.Drama': 'Drammatico',
  'genre.Family': 'Famiglia',
  'genre.Fantasy': 'Fantasy',
  'genre.History': 'Storico',
  'genre.Horror': 'Horror',
  'genre.Mystery': 'Mistero',
  'genre.Romance': 'Sentimentale',
  'genre.Sci-Fi': 'Fantascienza',
  'genre.Sport': 'Sport',
  'genre.Thriller': 'Thriller',
  'genre.War': 'Guerra',
  'genre.Western': 'Western',
  'genre.Reality-TV': 'Reality',
  'genre.Talk-Show': 'Talk show',
  'genre.Game-Show': 'Quiz',
  // Sports: favourite league
  'OK: show/hide or add · Hold OK: favourite league, or send an added league back to the bank': 'OK: mostra/nascondi o aggiungi · Tieni premuto OK: campionato preferito, o rimetti nell\'archivio un campionato aggiunto',
  'Make favourite league': 'Rendi campionato preferito',
  'Remove from favourite': 'Togli dai preferiti',
  '{tab} opens on it and its games come first in Live now': '{tab} si apre su di esso e le sue partite vengono prima in In diretta',
  'Send back to the league bank': 'Rimetti nell\'archivio dei campionati',
  'Favourite league': 'Campionato preferito',
  // Player side panel: Pull stats
  '◀ ▶ tabs  ·  OK to watch  ·  Hold OK for stats  ·  Back to close': '◀ ▶ schede  ·  OK per guardare  ·  Tieni premuto OK: statistiche  ·  Indietro per chiudere',
  // Sports hero on Windows
  'Click the game again or Enter: full screen  ·  Esc: stop': 'Clicca di nuovo la partita o Invio: schermo intero  ·  Esc: ferma',
  'Click again: watch here  ·  Hold: pick the channel': 'Clicca di nuovo: guarda qui  ·  Tieni premuto: scegli il canale',
  // Extras floating Search / Genre bar
  'Movie genres': 'Generi di film',
  'TV show genres': 'Generi di serie',
  // Extras: watched history + recent searches
  'Recently watched': 'Visti di recente',
  'Clear recent searches': 'Cancella ricerche recenti',
};
