// iOS build: the web build with the local API (youtubei.js) kept in, the sig iframe instead of the
// service worker, and the output written straight into the Capacitor app's web directory.
// The loopback proxy in ios/ makes YouTube reachable from the WebView, see ios/README.md
const path = require('path')
const { readFileSync } = require('fs')
const webpack = require('webpack')
const HtmlWebpackPlugin = require('html-webpack-plugin')
const CopyWebpackPlugin = require('copy-webpack-plugin')
const { sigFrameTemplateParameters } = require('./sigFrameConfig')
const config = require('./webpack.web.config.js')

const webOutput = path.join(__dirname, '../dist/web')
const iosOutput = path.join(__dirname, '../ios/App/App/public')

config.name = 'ios'
config.output.path = iosOutput
config.output.clean = true
delete config.externals
config.resolve.alias['youtubei.js$'] = 'youtubei.js/web'

config.plugins = config.plugins.map((plugin) => {
  if (plugin instanceof webpack.DefinePlugin && 'process.env.SUPPORTS_LOCAL_API' in plugin.definitions) {
    return new webpack.DefinePlugin({
      ...plugin.definitions,
      'process.env.SUPPORTS_LOCAL_API': true,
      'process.env.IS_IOS': true
    })
  }

  if (plugin instanceof HtmlWebpackPlugin) {
    return new HtmlWebpackPlugin({
      ...plugin.userOptions,
      templateParameters: {
        ...sigFrameTemplateParameters,
        iosPreloadScript: readFileSync(path.join(__dirname, '../src/renderer/iosPreloadScript.js'), 'utf8')
      }
    })
  }

  if (plugin instanceof CopyWebpackPlugin) {
    plugin.patterns = plugin.patterns
      .filter(pattern => !String(pattern.from).endsWith('pwabuilder-sw.js'))
      .map(pattern => typeof pattern.to === 'string' && pattern.to.startsWith(webOutput)
        ? { ...pattern, to: pattern.to.replace(webOutput, iosOutput) }
        : pattern)
  }

  return plugin
})

module.exports = config
