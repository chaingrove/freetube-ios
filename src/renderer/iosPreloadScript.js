// This is inlined into index.html by the iOS build and runs before any other script
// See index.ejs and _scripts/webpack.ios.config.js
//
// The WebView can't talk to YouTube directly (CORS preflights and forbidden headers),
// so requests for YouTube hosts go through the app's loopback proxy as /__yt/<encoded URL>.
// The URL is rewritten at request time and responses keep the original URL,
// so shaka-player and youtubei.js never see (and never double-wrap) a proxy URL.
(() => {
  const PROXIED_HOSTS = /(^|\.)(youtube\.com|googlevideo\.com|ytimg\.com|ggpht\.com|googleusercontent\.com)$/i
  const token = new URLSearchParams(location.search).get('ft') ?? ''

  /**
   * @param {string} url
   * @returns {string | null}
   */
  function proxyUrlFor(url) {
    let parsed
    try {
      parsed = new URL(url, location.href)
    } catch {
      return null
    }

    if (parsed.protocol !== 'https:') {
      return null
    }

    if (PROXIED_HOSTS.test(parsed.hostname) || (parsed.hostname === 'www.google.com' && parsed.pathname.startsWith('/js/'))) {
      return `/__yt/${encodeURIComponent(parsed.href)}`
    }

    return null
  }

  const originalFetch = window.fetch

  window.fetch = async (input, init) => {
    const isRequest = input instanceof Request
    const url = isRequest ? input.url : String(input)
    const proxyUrl = proxyUrlFor(url)

    if (proxyUrl === null) {
      return originalFetch(input, init)
    }

    let options = init ?? {}

    if (isRequest) {
      const fromRequest = {
        method: input.method,
        headers: input.headers,
        credentials: input.credentials,
        cache: input.cache,
        redirect: input.redirect,
        signal: input.signal
      }

      if (!('body' in options) && input.method !== 'GET' && input.method !== 'HEAD') {
        fromRequest.body = await input.arrayBuffer()
      }

      options = { ...fromRequest, ...options }
    }

    const headers = new Headers(options.headers)
    headers.set('X-FT-Token', token)

    const response = await originalFetch(proxyUrl, { ...options, headers })
    Object.defineProperty(response, 'url', { value: url })
    return response
  }

  const originalOpen = XMLHttpRequest.prototype.open

  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    const proxyUrl = proxyUrlFor(String(url))

    if (proxyUrl === null) {
      originalOpen.call(this, method, url, ...rest)
      return
    }

    originalOpen.call(this, method, proxyUrl, ...rest)
    this.setRequestHeader('X-FT-Token', token)
    Object.defineProperty(this, 'responseURL', { value: String(url), configurable: true })
  }

  // WebKit may evict website data under storage pressure unless it is marked as persistent
  navigator.storage?.persist?.()

  // iOS WebKit has screen.orientation without lock() and unlock(). shaka-player guards lock(),
  // but calls unlock() unguarded before leaving full screen, so its exit button would do nothing.
  // On the prototype, as WebKit can recreate the screen.orientation object and drop added properties.
  if (window.ScreenOrientation && !ScreenOrientation.prototype.unlock) {
    ScreenOrientation.prototype.unlock = () => {}
  }
})()
