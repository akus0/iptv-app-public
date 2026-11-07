# Stalker / MAC playlists

Choose **Stalker / MAC** in Add Playlist. Enter the provider's portal URL and the
MAC address registered for that subscription. This is a portal identity; the app
does not change or read the device's hardware MAC address.

The URL may be the portal's `/c/` page or its explicit PHP API endpoint. Optional
login, serial, device ID and signature fields are under **Additional provider
details**. Supply those only when required by the provider. Some subscriptions
are restricted to a particular device or client and require provider approval.

Live TV, Movies and Series use the existing content selectors and category
management. Portal guide data is imported automatically when supported; an
optional XMLTV URL takes precedence. **From phone** also accepts Stalker details,
including optional provider identity fields. Review the received details in the
app, then choose **Add Playlist**. Both LAN and encrypted relay transfer use the
same form; a separately hosted relay must serve the updated bundled form.

## Loading and playback

- Existing M3U and Xtream accounts do not make portal requests.
- A cached live catalogue restores without authentication or creating an HTTP
  client. Library categories and titles load when requested.
- Each portal session allows at most two concurrent API requests. Paging,
  response sizes and request duration are bounded. Large JSON and catalogue
  parsing runs off the UI isolate.
- Paged live loading reports the number of channels found, with progress updates
  limited to four per second apart from the initial and final counts. A transport
  timeout, connection failure or server error retries the affected live page
  once after a short delay. Authentication rejection, rate limiting and malformed
  content do not trigger this retry. Incomplete catalogues still never replace
  a saved catalogue.
- Token authentication and expiry recovery are shared by the session. A
  MAC-only panel is accepted only after a valid catalogue response, never after
  an explicit account rejection.
- Only a selected stream gets a temporary playback link. Favourites and history
  retain the stable portal command; session tokens and playback headers are not
  serialized. Clearly marked static streams can bypass link creation.
- API requests follow at most three redirects on the same origin, including a
  standard HTTP-to-HTTPS upgrade on the same host. Other hosts, ports and HTTPS
  downgrades are rejected without forwarding credentials. Successful canonical
  endpoints are reused for the session. Playback credentials remain scoped to
  the verified portal origin, including its accepted HTTPS upgrade.
- If the usual endpoints and MAC-only catalogue check are unsupported, discovery
  tries the original browser address once, following at most three safe redirects
  to derive the final portal path. That probe sends no MAC, bearer token or login
  details. Working endpoints and cached startup incur no additional requests.
- Native guide loading uses one bulk request per portal refresh and bounded
  database writes. Failed or empty refreshes retain the previous guide. There
  is no additional portal heartbeat or periodic catalogue polling.

## Compatibility and verification

The adapter implements the Stalker STB API, including handshake/profile/login,
the MAG profile fields and portal browser headers, live genres and channels,
paged movie/series catalogues, episode file lookup,
`create_link` and timestamp-based bulk EPG. It does not use Ministra's separate
administrator REST API. Providers expose different API subsets; unsupported
library sections can be empty even when live TV works. Device-bound signatures,
custom heartbeat requirements and nonstandard movie/series layouts may need
additional provider-specific work.

Portals that expose series only inside their VOD catalogue are not yet supported
as Series. Category names are not used to guess content type; that layout needs
explicit title/episode metadata and compatible playback resolution.

Automated tests use synthetic portal responses, not subscriber services. They
cover endpoint discovery, account rejection and renewal, request limits,
pagination failures, static/temporary streams, episode selection, credential
scoping, cache ownership, offline startup, guide retention, phone/TV layouts and
playback cancellation. Real-provider end-to-end playback remains unverified.

The protocol was researched against [Kodi's Stalker client](https://github.com/kodi-pvr/pvr.stalker),
[IPTVnator's Stalker architecture](https://github.com/4gray/iptvnator/blob/master/docs/architecture/stalker-portal.md)
and [Infomir's platform configuration documentation](https://wiki.infomir.eu/eng/ministra-tv-platform/ministra-installation-guide/configuration-file).
The adapter is independently implemented and adds no package dependency.
