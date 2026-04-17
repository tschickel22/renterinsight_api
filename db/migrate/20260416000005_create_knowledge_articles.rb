# frozen_string_literal: true

class CreateKnowledgeArticles < ActiveRecord::Migration[8.0]
  # article_type values: how_to, reference, faq, troubleshooting, concept, release_note
  def change
    create_table :knowledge_articles do |t|
      t.references :knowledge_module,  null: true, foreign_key: true, index: true
      t.references :knowledge_feature, null: true, foreign_key: true, index: true
      t.string  :title,        null: false
      t.string  :slug,         null: false
      t.text    :content
      t.text    :content_html
      t.text    :excerpt
      t.string  :article_type, null: false, default: 'how_to'
      t.integer :position,     null: false, default: 0
      t.boolean :is_published, null: false, default: false
      t.column  :embedding,    'vector(1536)'
      t.timestamps
    end

    add_index :knowledge_articles, :slug, unique: true
    add_index :knowledge_articles, :article_type
    add_index :knowledge_articles, [:is_published, :position]

    # HNSW index for cosine-similarity semantic search. Requires pgvector >= 0.5.
    # If your pgvector is older, replace with:
    #   USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)
    execute <<~SQL
      CREATE INDEX idx_knowledge_articles_on_embedding
        ON knowledge_articles
        USING hnsw (embedding vector_cosine_ops);
    SQL
  end
end
