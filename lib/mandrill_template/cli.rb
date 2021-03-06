require 'mandrill'
require 'mandrill_template/client'
require 'mandrill_template/template'
require 'formatador'
require 'unicode' unless ['jruby'].include?(RbConfig::CONFIG['ruby_install_name'])
require 'yaml'
require "mandrill_template/monkey_create_file"
require 'imgkit'
require 'erb'
autoload "Handlebars", 'handlebars'

class MandrillTemplateManager < Thor
  include Thor::Actions
  VERSION = "0.3.0"
  APP_ENVS = { 'dev' => "dev-", 'qa' => "qa-", 'prod' => "" }
  REPORT_DIR = 'report'
  class_option :env, :enum => %w{dev qa prod}, :banner => "<dev|qa|prod>", :desc => "Enables environment support by adding prefixes.", default: "prod"

  desc "export_all", "export all templates from remote to local files (does not include non-prod templates)."
  def export_all
    remote_templates = MandrillClient.client.templates.list
    remote_templates.each do |template|
      if !template["slug"].start_with?(APP_ENVS['dev']) and !template["slug"].start_with?(APP_ENVS['qa']) # skip non-prod templates
        export(template["slug"])
      end
    end
  end

  desc "export SLUG", "export template from remote to local files."
  def export(slug)
    template = MandrillClient.client.templates.info(slug)
    meta, code, text  = build_template_for_export(template)
    save_as_local_template(meta, code, text)
  end

  desc "upload SLUG", "upload template to remote as draft."
  option :publish, type: :boolean, default: false, aliases: :p
  def upload(slug)
    template = MandrillTemplate::Local.new(slug)
    
    if template.avail
      upload_template(template)
      publish(slug) if options[:publish]
    else
      puts "Template data not found #{slug}. Please generate first."
    end
  end
  
 desc "upload_all", "upload all template to remote as draft."
  option :publish, type: :boolean, default: false, aliases: :p
  def upload_all()
    labels = Dir.glob("#{ templates_directory }/*").map {|path| path.split(File::SEPARATOR).last}
    labels.each do |label|
      template = MandrillTemplate::Local.new(label)
      if template.avail
        upload_template(template)
        publish(label) if options[:publish]
        puts "Template published #{label}. feeling good."
      else
        puts "Template data not found #{label}. Please generate first."
      end
    end 
  end

  desc "delete SLUG", "delete template from remote."
  option :delete_local, type: :boolean, default: false
  def delete(slug)
    begin
      slug = add_slug_env_prefix(slug)
      result = MandrillClient.client.templates.delete(slug)
      puts result.to_yaml
    rescue Mandrill::UnknownTemplateError => e
      puts e.message
    end
    delete_local_template(slug) if options[:delete_local]
  end

  desc "generate SLUG", "generate new template files."
  def generate(slug)
    if slug.start_with?(APP_ENVS['dev']) or slug.start_with?(APP_ENVS['qa'])
      puts "Invalid template name. You cannot create environment templates directly. Use --env instead."
    else
      slug = add_slug_env_prefix(slug)
      new_template = MandrillTemplate::Local.new(slug)
      puts new_template.class
      meta, code, text = build_template_for_export(new_template)
      save_as_local_template(meta, code, text)
    end
  end

  desc "publish SLUG", "publish template from draft."
  def publish(slug)
    slug = add_slug_env_prefix(slug)
    puts MandrillClient.client.templates.publish(slug).to_yaml
  end

  desc "render SLUG [PARAMS_FILE]", "render mailbody from local template data. File should be Array. see https://mandrillapp.com/api/docs/templates.JSON.html#method=render."
  option :handlebars, type: :boolean, default: false
  def render(slug, params = nil)
    merge_vars =  params ? JSON.parse(File.read(params)) : []
    template = MandrillTemplate::Local.new(slug)
    if template.avail
      if options[:handlebars]
        handlebars = Handlebars::Context.new
        h_template = handlebars.compile(template['code'])
        puts h_template.call(localize_merge_vars(merge_vars))
      else
        result = MandrillClient.client.templates.render template.slug,
          [{"content"=>template["code"], "name"=>template.slug}],
          merge_vars
        puts result["html"]
      end
    else
      puts "Template data not found #{slug}. Please generate first."
    end
  end

  desc "report", "generate report for all local templates"
  def report()
    empty_directory REPORT_DIR
    labels = Dir.glob("#{ templates_directory }/*").map {|path| path.split(File::SEPARATOR).last}
    labels.each do |slug|
      template = MandrillTemplate::Local.new(slug)
      if template.avail
        kit = IMGKit.new(template['code'], :quality => 60, width: 600)
        file = kit.to_file(REPORT_DIR + "/#{slug}.png")
        puts "Preview for template '#{slug}' generated."
      else
        puts "Template data not found for '#{slug}'."
      end
    end

    @local_templates = collect_local_templates

    #erb_str = File.read('lib/report.html.erb')
    result = ERB.new(<<-EOS
      <html>
      <head><style>
              body {font-family: Arial, Helvetica, sans-serif;}
              table {border-spacing: 0; border-collapse: collapse; }
              th, td { padding: 10px; vertical-align: top; border: 1px solid #D0D7E1; }
              th { background-color: #D0D7E1; }
      </style></head>
      <body><table>
      <tr>
        <th>ID/Slug</th>
        <th>Name</th>
        <th>From</th>
        <th>Subject</th>
        <th>Template</th>
      </tr>
      <% @local_templates.each do |template| %>
      <tr>
        <td><%= template['slug'] %></td>
        <td><%= template['name'] %></td>
        <td><%= template['from'] %></td>
        <td><%= template['subject'] %></td>
        <td><img src="<%= template['slug'] %>.png"></td>
        </tr>
      <% end %>
      </table></body></html>
      EOS
    ).result(binding)
    
    html_file = REPORT_DIR + '/report.html'
    File.open(html_file, 'w') do |f|
      f.write(result)
    end
    puts "Report complete."
  end

  desc "list [LABEL]", "show template list both of remote and local [optionally filtered by LABEL]."
  option :verbose, type: :boolean, default: false, aliases: :v
  def list(label = nil)
    puts "Remote Templates"
    puts "----------------------"
    remote_templates = MandrillClient.client.templates.list(label)
    remote_templates.map! do |template|
      template["has_diff"] = has_diff_between_draft_and_published?(template)
      template
    end

    if options[:verbose]
    Formatador.display_compact_table(
      remote_templates,
      ["has_diff",
       "name",
       "slug",
       "publish_name",
       "draft_updated_at",
       "published_at",
       "labels",
       "subject",
       "publish_subject",
       "from_email",
       "publish_from_email",
       "from_name",
       "publish_from_name"]
    )
    else
      Formatador.display_compact_table(
        remote_templates,
        ["has_diff",
         "name",
         "slug",
         "from_email",
         "from_name",
         "subject",
         "labels",
         "from_name"]
      )
    end

    puts "Local Templates"
    puts "----------------------"
    Formatador.display_compact_table(
      collect_local_templates(label),
      [
        "name",
        "slug",
        "from_email",
        "from_name",
        "subject",
        "labels"
      ]
    )
  end

  private

  def has_diff_between_draft_and_published?(t)
    %w[name code text subject].each do |key|
      return true if t[key] != t["publish_#{key}"]
    end
    return true unless t['published_at']
    false
  end

  def build_template_for_export(t)
    [
      {
        "name"       => t['name'],
        "slug"       => t['slug'],
        "labels"     => t['labels'],
        "subject"    => t['subject'],
        "from_email" => t['from_email'],
        "from_name"  => t['from_name']
      },
      t['code'],
      t['text']
    ]
  end

  def templates_directory
    MandrillClient.templates_directory
  end

  def save_as_local_template(meta, code, text)
    dir_name = meta['slug']
    empty_directory File.join(templates_directory, dir_name)
    create_file File.join(templates_directory, dir_name, "metadata.yml"), meta.to_yaml
    create_file File.join(templates_directory, dir_name, "code.html"), code
    create_file File.join(templates_directory, dir_name, "text.txt"), text
  end

  def collect_local_templates(label = nil)
    local_templates = []
    dirs = Dir.glob("#{ templates_directory }/*").map {|path| path.split(File::SEPARATOR).last}
    dirs.map do |dir|
      begin
        template = MandrillTemplate::Local.new(dir)
        if label.nil? || template['labels'].include?(label)
          local_templates << template
        end
      rescue
        next
      end
    end
    local_templates
  end

  def delete_local_template(slug)
    template = MandrillTemplate::Local.new(slug)
    if template.avail
      template.delete!
    else
      puts "Local template data not found #{slug}."
    end
  end

  def upload_template(t)
    t.update_slug(add_slug_env_prefix(t.slug))
    
    if remote_template_exists?(t.slug)
      method = :update
    else
      method = :add
    end
    result = MandrillClient.client.templates.send(method, t.slug,
      t['from_email'],
      t['from_name'],
      t['subject'],
      t['code'],
      t['text'],
      false, # publish
      t['labels']
    )
    puts result.to_yaml
  end

  def add_slug_env_prefix(slug)
    APP_ENVS[options[:env]] + slug
  end

  def remote_template_exists?(slug)
    begin
      MandrillClient.client.templates.info(slug)
      true
    rescue Mandrill::UnknownTemplateError
      false
    end
  end

  def localize_merge_vars(merge_vars)
    h = {}
    merge_vars.each {|kv| h[kv["name"]] = kv["content"] }
    h
  end
end
