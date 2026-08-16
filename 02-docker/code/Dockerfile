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
ENV PYTHONPATH=/python
ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
