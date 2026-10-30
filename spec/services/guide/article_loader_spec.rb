# frozen_string_literal: true

require 'rails_helper'

# E88: the project management help articles load from db/guide/ by migration.
RSpec.describe Guide::ArticleLoader do
  let(:path) { Rails.root.join('db/guide/project_articles.yml') }
  let(:data) { YAML.safe_load_file(path) }
  let!(:projects) { Knowledge::Module.find_or_create_by!(key: 'projects') { |m| m.name = 'Projects' } }
  let!(:contractors) { Knowledge::Module.find_or_create_by!(key: 'contractors') { |m| m.name = 'Contractors' } }

  it 'adds every article, published, under its module' do
    result = described_class.load!(path)

    expect(result.created.size).to eq(data['articles'].size)
    expect(result.missing_modules).to be_empty
    loaded = Knowledge::Article.where(slug: data['articles'].map { |a| a['slug'] })
    expect(loaded.count).to eq(data['articles'].size)
    expect(loaded.pluck(:is_published).uniq).to eq([true])
    expect(Knowledge::Article.find_by(slug: 'review-updates').knowledge_module).to eq(projects)
    expect(Knowledge::Article.find_by(slug: 'contractor-portal-for-contractors').knowledge_module).to eq(contractors)
  end

  it 'never overwrites an article already there, and loading twice changes nothing' do
    edited = Knowledge::Article.create!(slug: 'review-updates', title: 'Mine', content: 'Hand edited',
                                        knowledge_module: projects, is_published: true)
    described_class.load!(path)
    expect(edited.reload.content).to eq('Hand edited')

    expect { described_class.load!(path) }.not_to change(Knowledge::Article, :count)
  end

  it 'unpublishes the articles it supersedes, without deleting them' do
    old = Knowledge::Article.create!(slug: 'project-templates', title: 'Old', content: 'x',
                                     knowledge_module: projects, is_published: true)
    result = described_class.load!(path)
    expect(old.reload.is_published).to be(false)
    expect(result.unpublished).to eq(['project-templates'])
  end

  it 'loads nothing for a module that does not exist, without failing' do
    contractors.destroy
    result = described_class.load!(path)
    expect(result.missing_modules).to eq(['contractors'])
    expect(Knowledge::Article.exists?(slug: 'contractor-portal-for-contractors')).to be(false)
  end

  it 'has no em or en dashes and unique slugs' do
    text = File.read(path)
    expect(text).not_to match(/[–—]/)
    slugs = data['articles'].map { |a| a['slug'] }
    expect(slugs.uniq.size).to eq(slugs.size)
  end
end
