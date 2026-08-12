#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"

apps = JSON.parse(ARGV[0])
repository = ENV.fetch("GITHUB_REPOSITORY").downcase
output_path = ENV.fetch("GITHUB_OUTPUT")

LAYERS = %w[base dev ros full].freeze

def native_arch_entry(arch)
  case arch
  when "amd64", "linux/amd64"
    { "arch" => "amd64", "platform" => "linux/amd64", "runner" => "ubuntu-latest" }
  when "arm64", "arm64/v8", "linux/arm64", "linux/arm64/v8"
    { "arch" => "arm64", "platform" => "linux/arm64", "runner" => "ubuntu-24.04-arm" }
  else
    raise "buildable app requests unsupported native architecture: #{arch}"
  end
end

def load_app(name)
  path = "apps/#{name}/app.yml"
  raise "missing #{path}" unless File.exist?(path)

  YAML.safe_load_file(path)
end

children = Hash.new { |h, k| h[k] = [] }
Dir.glob("apps/*/app.yml").each do |path|
  doc = YAML.safe_load_file(path)
  parent = doc["dependsOnApp"]
  next if parent.nil? || parent.empty?

  children[parent] << doc.fetch("key")
end

def descendants_of(app, children)
  out = []
  stack = children[app].dup
  while (current = stack.pop)
    next if out.include?(current)

    out << current
    stack.concat(children[current])
  end
  out
end

expanded = apps.dup
seen = expanded.to_h { |app| [app, true] }

expanded.dup.each do |app|
  next unless File.exist?("apps/#{app}/app.yml")

  doc = load_app(app)
  if doc["type"] == "build"
    descendants_of(app, children).each do |child|
      next if seen[child]

      expanded << child
      seen[child] = true
    end
    next
  end

  dependency = doc["dependsOnApp"]
  next if dependency.nil? || dependency.empty? || seen[dependency]
  next if doc["rebuildDependency"] == false

  expanded << dependency
  seen[dependency] = true
end

legacy_build = []
legacy_dependent_build = []
mirror = []
legacy_manifest = []
legacy_dependent_manifest = []
layer_build = LAYERS.to_h { |layer| [layer, []] }
layer_manifest = LAYERS.to_h { |layer| [layer, []] }

expanded.each do |app|
  doc = load_app(app)
  version = doc.fetch("version")
  image = "ghcr.io/#{repository}/#{app}"
  architectures = Array(doc["architectures"] || ["amd64"])
  buildable = File.exist?("apps/#{app}/Dockerfile")
  parent = doc["dependsOnApp"]
  parent_image = nil
  if parent && !parent.empty?
    parent_doc = load_app(parent)
    parent_image = "ghcr.io/#{repository}/#{parent}:#{parent_doc.fetch("version")}"
  end

  unless buildable
    mirror << {
      "app" => app,
      "version" => version,
      "image" => image,
      "source_image" => doc["upstreamImage"] || doc["image"],
      "architectures" => architectures
    }
    next
  end

  entries = architectures.map { |arch| native_arch_entry(arch) }
  multiarch = entries.length > 1
  layer = doc["type"] == "build" ? doc.fetch("buildLayer") : nil
  raise "build app #{app} has unknown buildLayer #{layer.inspect}" if doc["type"] == "build" && !LAYERS.include?(layer)

  build_rows = entries.map do |entry|
    row = entry.merge(
      "app" => app,
      "version" => version,
      "image" => image,
      "multiarch" => multiarch,
      "no_cache" => doc["noCache"] == true,
      "version_only" => doc["publishVersionOnly"] == true,
      "context" => doc["type"] == "build" ? "." : "apps/#{app}",
      "file" => doc["type"] == "build" ? "apps/#{app}/Dockerfile" : "apps/#{app}/Dockerfile",
      "parent_image" => if parent_image
                          "#{parent_image}-#{entry["arch"]}"
                        elsif doc["fromImage"]
                          doc["fromImage"]
                        else
                          ""
                        end
    )
    row
  end

  manifest_row = {
    "app" => app,
    "version" => version,
    "image" => image,
    "arches" => entries.map { |entry| entry["arch"] }
  }

  if layer
    layer_build[layer].concat(build_rows)
    layer_manifest[layer] << manifest_row if multiarch
  else
    target = parent ? legacy_dependent_build : legacy_build
    manifest_target = parent ? legacy_dependent_manifest : legacy_manifest
    target.concat(build_rows)
    manifest_target << manifest_row if multiarch
  end
end

def matrix(rows)
  JSON.generate({ "include" => rows })
end

File.open(output_path, "a") do |out|
  out.puts "build_matrix=#{matrix(legacy_build)}"
  out.puts "dependent_build_matrix=#{matrix(legacy_dependent_build)}"
  out.puts "mirror_matrix=#{matrix(mirror)}"
  out.puts "manifest_matrix=#{matrix(legacy_manifest)}"
  out.puts "dependent_manifest_matrix=#{matrix(legacy_dependent_manifest)}"
  LAYERS.each do |layer|
    out.puts "build_layer_#{layer}=#{matrix(layer_build[layer])}"
    out.puts "manifest_layer_#{layer}=#{matrix(layer_manifest[layer])}"
  end
end

warn "legacy build=#{legacy_build.length} dependent=#{legacy_dependent_build.length} mirror=#{mirror.length}"
LAYERS.each do |layer|
  warn "layer #{layer}=#{layer_build[layer].length}"
end
