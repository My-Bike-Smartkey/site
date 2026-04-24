require 'xcodeproj'
project_path = 'DatBikeSmartkey.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

group = project.main_group.find_subpath(File.join('DatBikeSmartkey', 'Views', 'Settings'), true)
group.set_source_tree('<group>')
group.set_path('DatBikeSmartkey/Views/Settings')

files = [
  'DatBikeSmartkey/Views/Settings/MyBikeSettingsView.swift',
  'DatBikeSmartkey/Views/Settings/ConnectionSettingsView.swift',
  'DatBikeSmartkey/Views/Settings/DeveloperSettingsView.swift',
  'DatBikeSmartkey/Views/Settings/NotificationSettingsView.swift'
]

files.each do |file_path|
  file_ref = group.new_file(file_path)
  target.add_file_references([file_ref])
end

project.save
