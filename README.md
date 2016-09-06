# What is this?

Experimental ruby shell to RH Satellite 6 using apipie-bindings.

_Very_ experimental!

# Why?

Yes there is hammer-cli but writing things like this

```bash
hammer longresourcename actionname --very-long-parameter-name foo --another-very-long-parameter 1

```

felt somehow wrong. Instead I wanted to have something a bit more
programmable than shell script. Something like:

```ruby
def clean_orphan_versions
  set_default organization_id: organization.by(name: "Oorgh").id
  content_views.index.each do |cv|
    d=cv.data
    id=cv.id
    d['versions'].each do |ver|
      if ver['environment_ids']==[]
        puts "content_view: #{d['name']} version: #{ver['version']} envs: #{ver['environment_ids']}"
        wait_task content_view_versions.destroy(id: ver['id'])
      end
    end
  end
end
```

# Is this ready?

Not by far. 
