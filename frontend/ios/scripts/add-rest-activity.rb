# Adds the Live Activity pieces to ios/App/App.xcodeproj, once (re-running changes nothing):
#   - App target: AppViewController.swift, RestAlertPlugin.swift, Shared/RestActivity.swift;
#     drops PrintPlugin.m (PrintPlugin.swift registers itself through AppViewController now)
#   - RestActivity: a WidgetKit extension drawing the rest countdown, embedded in the app
#
#   ruby frontend/ios/scripts/add-rest-activity.rb
#
# Uses the xcodeproj gem that CocoaPods ships with. With Homebrew's CocoaPods:
#   GEM_PATH="$(ls -d /opt/homebrew/Cellar/cocoapods/*/libexec):$(ruby -e 'print Gem.default_dir')" ruby …
require 'xcodeproj'

ROOT = File.expand_path('../App', __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, 'App.xcodeproj'))
app = project.targets.find { |t| t.name == 'App' } or abort 'no App target'
main = project.main_group

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
app_group = main.children.find { |g| g.respond_to?(:path) && g.path == 'App' } or abort 'no App group'
add_source(app_group, app, 'AppViewController.swift')
add_source(app_group, app, 'RestAlertPlugin.swift')
if (m = app_group.files.find { |f| f.path == 'PrintPlugin.m' })
  app.source_build_phase.files.select { |bf| bf.file_ref == m }.each(&:remove_from_project)
  m.remove_from_project
end

shared = group_for(project, 'Shared')
shared_ref = add_source(shared, app, 'RestActivity.swift')

# --- RestActivity widget extension -----------------------------------------------------------
ext = project.targets.find { |t| t.name == 'RestActivity' }
unless ext
  ext = project.new_target(:app_extension, 'RestActivity', :ios, '17.0', nil, :swift)
  ext_group = group_for(project, 'RestActivity')
  add_source(ext_group, ext, 'RestActivityWidget.swift')
  ext_group.new_reference('Info.plist') unless ext_group.files.any? { |f| f.path == 'Info.plist' }
  ext.source_build_phase.add_file_reference(shared_ref, true)
  %w[WidgetKit SwiftUI ActivityKit AppIntents].each do |fw|
    ext.add_system_framework(fw)
  end

  app_settings = app.build_configurations.first.build_settings
  ext.build_configurations.each do |c|
    s = c.build_settings
    s['INFOPLIST_FILE'] = 'RestActivity/Info.plist'
    s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{app_settings['PRODUCT_BUNDLE_IDENTIFIER']}.RestActivity"
    s['PRODUCT_NAME'] = '$(TARGET_NAME)'
    s['SWIFT_VERSION'] = '5.0'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
    s['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    s['CODE_SIGN_STYLE'] = 'Automatic'
    s['DEVELOPMENT_TEAM'] = app_settings['DEVELOPMENT_TEAM'] if app_settings['DEVELOPMENT_TEAM']
    s['MARKETING_VERSION'] = app_settings['MARKETING_VERSION'] || '1.0'
    s['CURRENT_PROJECT_VERSION'] = app_settings['CURRENT_PROJECT_VERSION'] || '1'
    s['SKIP_INSTALL'] = 'YES'
    s['GENERATE_INFOPLIST_FILE'] = 'NO'
    s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  end

  app.add_dependency(ext)
  embed = app.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' } ||
          app.new_copy_files_build_phase('Embed Foundation Extensions')
  embed.dst_subfolder_spec = Xcodeproj::Constants::COPY_FILES_BUILD_PHASE_DESTINATIONS[:plug_ins]
  bf = embed.add_file_reference(ext.product_reference, true)
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

project.save
puts "RestActivity extension: #{ext.uuid}"
