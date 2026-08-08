(asdf:defsystem :monitor-sites
  :description "Monitor web sites and send Mattermost alerts"
  :author "Donnie"
  :license "MIT"
  :depends-on (:drakma :dc-eclectic :dc-time :p-log :cl-ppcre :hunchentoot :swank)
  :components ((:file "monitor-sites-package")
                (:file "eval-safely")
                (:file "read-conf")
                (:file "monitor-sites"))
  :build-operation "program-op"
  :build-pathname "monitor-sites"
  :entry-point "monitor-sites:main")
