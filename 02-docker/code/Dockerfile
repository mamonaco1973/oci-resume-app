# Build stage: install Python dependencies into /python so the runtime
# image stays lean.  fnproject/python:3.11-dev includes pip and build tools.
FROM fnproject/python:3.11-dev as build-stage
WORKDIR /function
ADD requirements.txt /function/
RUN pip3 install --target /python/ --no-cache -r requirements.txt \
    && rm -fr ~/.cache/pip /tmp*

# Runtime stage: copy installed packages and function source only.
FROM fnproject/python:3.11
WORKDIR /function
COPY --from=build-stage /python /python
ADD . /function/
RUN chmod 755 /function/func.py

# /function is on the path as well as /python because this handler is split
# across sibling modules (common, jobs, resumes, folders, users, attachments,
# nosql_util, os_util, worker) rather than living in one file.
#
# The entrypoint runs the fdk script, so Python seeds sys.path with the fdk's
# own directory — /python/bin — not /function. Without /function here, every
# `import common` in func.py raises ImportError before the handler is ever
# registered, the container fails to start, and API Gateway reports a bare 502
# on every route with nothing in the function log to explain it.
ENV PYTHONPATH=/python:/function
ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
