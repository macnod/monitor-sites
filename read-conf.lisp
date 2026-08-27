(in-package :monitor-sites)

(pl:make-log-stream
  "monitor-sites"
  "monitor-sites.log"
  :severity-threshold :info)

(pl:make-log-stream
  "monitor-sites-stdout"
  *standard-output*
  :severity-threshold :info)

(defun report (severity plist)
  (pl:plog severity plist)
  (when (equal severity :error)
    (error "~{~a=~a~^; ~}" plist)))

(defparameter *required-keys*
  '(:check-interval (:type :integer :min 10 :max 86400)
     :retry-connectivity-time (:type :integer :min 10 :max 3600)
     :lost-connectivity-time (:type :integer :min 1 :max 86400)
     :max-connectivity-retries (:type :integer :min 1 :max 100)
     :connectivity-urls (:type :list
                          :min-length 1
                          :max-length 10
                          :value (:type :string
                                   :min-length 12
                                   :max-length 200))
     :mattermost-url (:type :string :min-length 12 :max-length 200)
     :mattermost-token (:type :string :min-length 4 :max-length 64)
     :mattermost-channel-id (:type :string :min-length 4 :max-length 64)
     :max-log-lines (:type :integer :min 10 :max 1000000)
     :http-port (:type :integer :min 1 :max 65535)
     :log-path (:type :string :min-length 1 :max-length 250)
     :ca-directory (:type :string :min-length 2 :max-length 250)
     :ca-cert (:type :string :min-length 2 :max-length 250)
     :user-agent (:type :string :min-length 2 :max-length 200)
     :heartbeat-interval (:type :integer :min 0 :max 604800)
    :heartbeat-start-at (:type :string
                         :min-length 4
                         :max-length 5
                         :optional t)
     :sites (:type :map
              :min-length 1
              :max-length 100
              :value (:name (:type :string :min-length 1 :max-length 100)
                       :url (:type :string :min-length 12 :max-length 400)
                       :expect (:type :string :min-length 1 :max-length 100)
                       :user-agent (:type :string
                                     :min-length 1 :max-length 200
                                     :optional t)
                       :ca-directory (:type :string
                                       :min-length 1 :max-length 200
                                       :optional t)
                       :ca-cert (:type :string
                                  :min-length 1 :max-length 200
                                  :optional t)))))

(defun required-keys (path)
    (u:plist-keys (apply #'u:tree-get (cons *required-keys* (reverse path)))))

(defun short-list (l)
  (let ((list-length (length l)))
    (format nil "~{~a~^, ~}~a"
      (if (> list-length 3) (subseq l 0 3) l)
      (if (> list-length 3) "..." ""))))

(defun valid-integer (path val)
  (pl:pdebug :in "valid-integer" :path path :val val)
  (unless (integerp val)
    (report :error `(:in "valid-integer"
                      :status "invalid integer"
                      :path ,(reverse path)
                      :value ,val)))
  (let* ((node (apply #'u:tree-get (cons *required-keys* (reverse path))))
          (min (getf node :min))
          (max (getf node :max)))
    (unless (<= min val max)
      (report :error `(:in "valid-integer"
                        :status "integer out of bounds"
                        :min ,min :max ,max :val ,val :path ,path)))))

(defun valid-string (path val)
  (pl:pdebug :in "valid-string" :path path :val (clean-value (car path) val))
  (let ((node (apply #'u:tree-get (cons *required-keys* (reverse path)))))
    (cond
      ;; Absent optional key: nothing more to check.
      ((and (getf node :optional) (null val)))
      ((not (stringp val))
        (report :error `(:in "valid-string"
                          :status "invalid string"
                          :path ,(reverse path)
                          :value ,val)))
      (t
        (let* ((min-length (getf node :min-length))
                (max-length (getf node :max-length))
                (val-length (length val)))
          (unless (<= min-length val-length max-length)
            (let ((val-clean (clean-value (car path) val)))
              (report :error `(:in "valid-string"
                                :status "string length out of bounds"
                                :min-length ,min-length
                                :max-length ,max-length
                                :value-length ,val-length
                                :value ,val-clean)))))))))

(defun clean-value (key val)
  (case key
    (:mattermost-token
      (re:regex-replace-all "." val "X"))
    (:mattermost-channel-id
      (re:regex-replace-all "." val "X"))
    (t val)))

(defun valid-value (conf path)
  (pl:pdebug :in "valid-value" :path path :type-path (reverse (cons :type path)))
  (let* ((val (apply #'u:tree-get (cons conf (reverse path))))
          (val-clean (clean-value (car path) val)))
    (pl:pdebug :in "valid-value" :val val-clean)
    (let ((type (apply #'u:tree-get (cons *required-keys* (reverse (cons :type path))))))
      (pl:pdebug :in "valid-value" :val val-clean :type type)
      (case type
        (:integer (valid-integer path val))
        (:string (valid-string path val))
        (:list (valid-list conf path))
        (:map (valid-map conf path))
        (:plist (valid-plist conf path))
        (otherwise (report :error `(:in "valid-value"
                                     :status "unknown configuration key type"
                                     :keys path
                                     :type ,(getf val :type))))))))

(defun valid-plist (conf path)
  (pl:pdebug :in "valid-plist" :path path)
  (loop
    with conf-node = (apply #'u:tree-get (cons conf (reverse path)))
    for key in conf-node by #'cddr
    for val in (cdr conf-node) by #'cddr
    for val-clean = (clean-value key val)
    for log = (pl:pdebug :in "valid-plist" :key key :val val-clean)
    do (valid-value conf (cons key path))
    collect key into keys
    finally
    (let* ((spec-node (apply #'u:tree-get
                             (cons *required-keys* (reverse path))))
           (missing (set-difference
                      (remove-if
                        (lambda (k)
                          (u:tree-get spec-node k :optional))
                        (required-keys path))
                      keys))
           (unknown (set-difference keys (required-keys path))))
      (when missing
        (report :error `(:in "valid-plist"
                          :status "missing keys in configuration"
                          :keys ,(format nil "~{~s~^, ~}" missing))))
      (when unknown
        (report :error `(:in "valid-plist"
                          :status "unknown keys in configuration"
                          :keys ,(format nil "~{~s~^, ~}" unknown)))))))

(defun valid-map (conf path)
  (pl:pdebug :in "valid-map" :path path)
  (let ((conf-node (apply #'u:tree-get (cons conf (reverse path))))
        (spec-node (apply #'u:tree-get
                          (cons *required-keys* (reverse path)))))
    (unless (u:plistp conf-node)
      (report :error `(:in "valid-map"
                        :status "not a plist"
                        :keys ,(reverse path))))
    (let ((min-length (getf spec-node :min-length))
           (max-length (getf spec-node :max-length)))
      (loop for key in conf-node by #'cddr
            count key into count
            finally
            (unless (<= min-length count max-length)
              (report :error `(:in "valid-map"
                                :status "map size out of bounds"
                                :min-length ,min-length
                                :max-length ,max-length
                                :count ,count
                                :keys ,(reverse path))))))
    (loop for key in conf-node by #'cddr
          for val = (getf conf-node key)
          for site-path = (cons key path)
          do (valid-map-entry conf site-path spec-node))))

(defun valid-map-entry (conf site-path spec-node)
  (let ((value-spec (getf spec-node :value))
        (site-val (apply #'u:tree-get (cons conf (reverse site-path)))))
    (unless (u:plistp site-val)
      (report :error `(:in "valid-map-entry"
                        :status "site value is not a plist"
                        :keys ,(reverse site-path)
                        :value ,site-val)))
    (loop with site-keys = nil
          for key in site-val by #'cddr
          for val = (getf site-val key)
          for field-spec = (getf value-spec key)
          do (unless field-spec
               (report :error `(:in "valid-map-entry"
                                 :status "unknown key in site"
                                 :key ,key
                                 :keys ,(reverse site-path))))
             (let ((field-type (getf field-spec :type))
                    (optional (getf field-spec :optional)))
               (case field-type
                 (:string
                  (unless (or (stringp val) (and optional (null val)))
                    (report :error `(:in "valid-map-entry"
                                      :status "invalid string"
                                      :key ,key
                                      :keys ,(reverse site-path)
                                      :value ,val)))
                  (let ((min-len (getf field-spec :min-length))
                        (max-len (getf field-spec :max-length))
                        (len (length val)))
                    (unless (<= min-len len max-len)
                      (report :error `(:in "valid-map-entry"
                                        :status "string length out of bounds"
                                        :key ,key
                                        :min-length ,min-len
                                        :max-length ,max-len
                                        :value-length ,len
                                        :keys ,(reverse site-path))))))
                 (:integer
                  (unless (integerp val)
                    (report :error `(:in "valid-map-entry"
                                      :status "invalid integer"
                                      :key ,key
                                      :keys ,(reverse site-path)
                                      :value ,val)))
                  (let ((min (getf field-spec :min))
                        (max (getf field-spec :max)))
                    (unless (<= min val max)
                      (report :error `(:in "valid-map-entry"
                                        :status "integer out of bounds"
                                        :key ,key
                                        :min ,min :max ,max
                                        :val ,val
                                        :keys ,(reverse site-path))))))
                 (otherwise
                  (report :error `(:in "valid-map-entry"
                                    :status "unsupported field type in map value spec"
                                    :key ,key
                                    :type ,field-type)))))
             (push key site-keys)
          finally
          (let ((missing (set-difference
                           (remove-if
                             (lambda (k)
                               (u:tree-get value-spec k :optional))
                             (u:plist-keys value-spec))
                           site-keys)))
            (when missing
              (report :error `(:in "valid-map-entry"
                                :status "missing keys in site"
                                :keys ,(reverse site-path)
                                :missing ,(format nil "~{~s~^, ~}"
                                                   missing))))))))

(defun valid-list (conf path)
  (loop
    with conf-list = (apply #'u:tree-get (cons conf (reverse path)))
    with list-length = (length conf-list)
    with types-node = (apply #'u:tree-get (cons *required-keys* (reverse path)))
    with min-length = (getf types-node :min-length)
    with max-length = (getf types-node :max-length)
    with types-subnode = (getf types-node :value)
    with element-type = (getf types-subnode :type)
    with element-min-length = (getf types-subnode :min-length)
    with element-max-length = (getf types-subnode :max-length)
    initially
    (unless (listp conf-list)
      (report :error `(:in "valid-list"
                        :status "not a list"
                        :list (short-list conf-list)
                        :keys ,(reverse path))))
    (when (or (< list-length min-length) (> list-length max-length))
      (report :error `(:in "valid-list"
                        :status "length of list is out of bounds"
                        :list ,(short-list conf-list)
                        :length ,list-length
                        :min-length ,min-length
                        :max-length ,max-length
                        :keys ,(reverse path))))
    for value in conf-list
    for value-length = (length value)
    for predicate = (case element-type
                      (:string #'stringp)
                      (:integer #'integerp)
                      (t (report :error `(:in "valid-list"
                                           :status "invalid type specifier"
                                           :type-specifier ,element-type
                                           :keys ,(reverse path)))))
    unless (funcall predicate value)
    do (report :error `(:in "valid-list"
                         :status "invalid value type"
                         :value ,value
                         :keys ,(reverse path)))
    unless (and
             (>= value-length element-min-length)
             (<= value-length element-max-length))
    do (report :error `(:in "valid-list"
                         :status "element length out of bounds"
                         :value ,value
                         :keys ,(reverse path)))))

(defun valid-conf (conf &optional path (type :plist))
  (pl:pdebug :in "valid-conf")
  (case type
    (:plist (valid-plist conf path))
    (:list (valid-list conf path))
    (:map (valid-map conf path))
    (otherwise (report :error `(:in "valid-conf"
                                 :status "unknown node type"
                                 :path ,path :type ,type)))))

(defun load-config ()
  (let* ((path (or (u:getenv "MONITOR_SITES_CONF")
                   "monitor-sites-conf.lisp"))
         (conf (cadr (read-from-string (u:slurp path)))))
    (valid-conf conf)
    ;; Validate :heartbeat-start-at shape too, inside the normal
    ;; keep-last-good-configuration error path.
    (when (getf conf :heartbeat-start-at)
      (parse-hh-mm (getf conf :heartbeat-start-at)))
    conf))
