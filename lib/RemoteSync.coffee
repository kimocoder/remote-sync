
path = require "path"

os = null
exec = null

fs = require "fs-plus"
SETTINGS_FILE_NAME = ".remote-sync.json"
{$} = require "atom"
logger = null
configPath = null

file = null
settings = null
editorSubscription = null
bufferSubscriptionList = {}
transport = null

uploadCmd = null
downloadCmd = null


module.exports =
  configDefaults:
    logToConsole: false
    difftoolCommand: 'diffToolPath'

  activate: ->
    Logger = require "./Logger"
    logger = new Logger "Remote Sync"

    configPath = path.join atom.project.getPath(), SETTINGS_FILE_NAME
    if fs.existsSync(configPath)
      load()
    else
      console.error "cannot find sync-config: #{configPath}"

    atom.workspaceView.command "remote-sync:download-all", ->
      return logger.error("#{configPath} not exists") if not settings
      download(atom.project.getPath())

    atom.workspaceView.command "remote-sync:reload-config", ->
      load()

    atom.workspaceView.command 'remote-sync:upload', (e)->
      [localPath, isFile] = getSelectPath e
      if isFile
        handleSave(localPath)
      else
        uploadPath(localPath)

    atom.workspaceView.command 'remote-sync:download', (e)->
      return logger.error("#{configPath} not exists") if not settings
      # filePath = path.join atom.project.getPath(), $(e.target).attr("data-path")
      [localPath, isFile] = getSelectPath e
      if isFile
        return if settings.isIgnore(localPath)
        localPath = atom.project.relativize(localPath)
        getTransport().download(path.resolve(settings.target, localPath))
      else
        download(localPath)

    atom.workspaceView.command 'remote-sync:diff', (e)->
      return logger.error("#{configPath} not exists") if not settings
      [localPath, isFile] = getSelectPath e
      os = require "os" if not os
      targetPath = path.join os.tmpDir(), "remote-sync-"+path.basename(localPath)
      diff = ->
        diffCmd = atom.config.get('remote-sync.difftoolCommand')
        exec    = require("child_process").exec if not exec
        exec "#{diffCmd} #{localPath} #{targetPath}", (err)->
          logger.error """Check the field value of difftool Command in your settings (remote-sync).
           Command error: #{err}
           command: #{diffCmd} #{localPath} #{targetPath}
           """

      if isFile
        return if settings.isIgnore(localPath)
        getTransport().download(path.resolve(settings.target, atom.project.relativize(localPath)), targetPath, diff)
      else
        download(localPath, targetPath, diff)

findFileParent = (node) ->
  parent = node.parent()
  return parent if parent.is('.file') or parent.is('.directory')
  findFileParent(parent)

getSelectPath = (e) ->
    selected = findFileParent($(e.target))
    [selected.view().getPath(), selected.is('.file')]

download = (localPath, targetPath, callback)->
  if not downloadCmd
    downloadCmd = require './commands/DownloadAllCommand'
  downloadCmd.run(logger, getTransport(), localPath, targetPath, callback)

minimatch = null
load = ->
  try
    settings = JSON.parse fs.readFileSync(configPath)
  catch err
    deinit() if editorSubscription
    logger.error "load #{configPath}, #{err}"
    return

  console.log("setting: ", settings)

  if settings.uploadOnSave
    init() if not editorSubscription
  else
    unsubscript if editorSubscription

  if settings.ignore and not Array.isArray settings.ignore
    settings.ignore = [settings.ignore]

  settings.isIgnore = (filePath, relativizePath) ->
    return false if not settings.ignore
    if not relativizePath
      filePath = atom.project.relativize filePath
    else
      filePath = path.relative relativizePath, filePath
    minimatch = require "minimatch" if not minimatch
    for pattern in settings.ignore
      return true if minimatch filePath, pattern, { matchBase: true }
    return false

  if transport
    old = transport.settings
    if old.username != settings.username or old.hostname != settings.hostname or old.port != settings.port
      transport.dispose()
      transport = null
    else
      transport.settings = settings

init = ->
  editorSubscription = atom.workspace.eachEditor (editor) ->
    buffer = editor.getBuffer()
    bufferSavedSubscription = buffer.on 'saved', ->
      handleSave(buffer.getUri())

    bufferSubscriptionList[bufferSavedSubscription] = true
    buffer.on "destroyed", ->
      bufferSavedSubscription.off()
      delete bufferSubscriptionList[bufferSavedSubscription]

handleSave = (filePath) ->
  return if settings.isIgnore(filePath)

  if not uploadCmd
    UploadListener = require "./UploadListener"
    uploadCmd = new UploadListener logger
    console.log("handleSave, createUpload ")

  uploadCmd.handleSave(filePath, getTransport())

uploadPath = (dirPath)->
  onFile = (filePath)->
    handleSave(filePath)

  onDir = (dirPath)->
    return not settings.isIgnore(dirPath)

  fs.traverseTree dirPath, onFile, onDir

unsubscript = ->
  editorSubscription.off()
  editorSubscription = null

  for bufferSavedSubscription, v of bufferSubscriptionList
    bufferSavedSubscription.off()

  bufferSubscriptionList = {}

deinit = ->
  unsubscript()
  settings = null

getTransport = ->
  return transport if transport
  ScpTransport = require "./transports/ScpTransport"
  transport = new ScpTransport logger, settings
