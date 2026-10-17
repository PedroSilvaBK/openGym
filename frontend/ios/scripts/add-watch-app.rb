# Adds the Apple Watch app to ios/App/App.xcodeproj, once (re-running changes nothing):
#   - App target: WatchLink.swift, WatchPlugin.swift, HealthKit (App/App.entitlements)
#   - Watch: a watchOS SwiftUI app (ios/App/Watch), embedded in the iPhone app
#
#   GEM_PATH="$(ls -d /opt/homebrew/Cellar/cocoapods/*/libexec):$(ruby -e 'print Gem.default_dir')" \
#     ruby frontend/ios/scripts/add-watch-app.rb
require 'xcodeproj'

ROOT = File.expand_path('../App', __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, 'App.xcodeproj'))
app = project.targets.find { |t| t.name == 'App' } or abort 'no App target'

def group_for(project, path)
  project.main_group.children.find { |g| g.respond_to?(:path) && g.path == path } ||
    project.main_group.new_group(path, path)
end

def add_source(group, target, name)
  ref = group.files.find { |f| f.path == name } || group.new_reference(name)
  target.source_build_phase.add_file_reference(ref, true)
  ref
end

# --- App target ---------------------------------------------------------------------------
app_group = group_for(project, 'App')
add_source(app_group, app, 'WatchLink.swift')
add_source(app_group, app, 'WatchPlugin.swift')
add_source(app_group, app, 'RecordingUploader.swift')
app_group.new_reference('App.entitlements') unless app_group.files.any? { |f| f.path == 'App.entitlements' }
app.add_system_framework('HealthKit')
app.add_system_framework('WatchConnectivity')
app.build_configurations.each { |c| c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'App/App.entitlements' }

# --- Watch app ----------------------------------------------------------------------------
watch = project.targets.find { |t| t.name == 'Watch' }
unless watch
  watch = project.new_target(:application, 'Watch', :watchos, '11.0', nil, :swift)
  group = group_for(project, 'Watch')
  %w[Info.plist Watch.entitlements].each do |f|
    group.new_reference(f) unless group.files.any? { |r| r.path == f }
  end
  %w[SwiftUI WatchKit WatchConnectivity HealthKit].each { |fw| watch.add_system_framework(fw) }

  app_settings = app.build_configurations.first.build_settings
  app_id = app_settings['PRODUCT_BUNDLE_IDENTIFIER']
  watch.build_configurations.each do |c|
    s = c.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{app_id}.watchkitapp"
    s['PRODUCT_NAME'] = 'openGym'
    s['SDKROOT'] = 'watchos'
    s['TARGETED_DEVICE_FAMILY'] = '4'
    s['WATCHOS_DEPLOYMENT_TARGET'] = '11.0'
    s['SWIFT_VERSION'] = '5.0'
    s['CODE_SIGN_STYLE'] = 'Automatic'
    s['CODE_SIGN_ENTITLEMENTS'] = 'Watch/Watch.entitlements'
    s['DEVELOPMENT_TEAM'] = app_settings['DEVELOPMENT_TEAM'] if app_settings['DEVELOPMENT_TEAM']
    s['MARKETING_VERSION'] = app_settings['MARKETING_VERSION'] || '1.0'
    s['CURRENT_PROJECT_VERSION'] = app_settings['CURRENT_PROJECT_VERSION'] || '1'
    s['SKIP_INSTALL'] = 'YES'
    s['GENERATE_INFOPLIST_FILE'] = 'YES'
    s['INFOPLIST_FILE'] = 'Watch/Info.plist'
    s['INFOPLIST_KEY_CFBundleDisplayName'] = 'openGym'
    s['INFOPLIST_KEY_WKCompanionAppBundleIdentifier'] = app_id
    s['INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp'] = 'NO'
    s['INFOPLIST_KEY_NSHealthShareUsageDescription'] = 'openGym shows your heart rate and calories while you train.'
    s['INFOPLIST_KEY_NSHealthUpdateUsageDescription'] = 'openGym saves the workouts you track on your Apple Watch to Health.'
    s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']
    s['ENABLE_PREVIEWS'] = 'YES'
  end

  app.add_dependency(watch)
  embed = app.copy_files_build_phases.find { |p| p.name == 'Embed Watch Content' } ||
          app.new_copy_files_build_phase('Embed Watch Content')
  embed.dst_subfolder_spec = Xcodeproj::Constants::COPY_FILES_BUILD_PHASE_DESTINATIONS[:products_directory]
  embed.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
  bf = embed.add_file_reference(watch.product_reference, true)
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

# Sources, also for a project that has the target already (re-running adds new files).
WATCH_SOURCES = %w[OpenGymWatchApp.swift Snapshot.swift WatchModel.swift WorkoutManager.swift Views.swift SensorRecorder.swift]
watch_group = group_for(project, 'Watch')
WATCH_SOURCES.each { |f| add_source(watch_group, watch, f) }
watch.add_system_framework('CoreMotion')

project.save
puts "Watch app: #{watch.uuid}"
