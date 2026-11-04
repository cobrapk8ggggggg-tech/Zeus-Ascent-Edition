import asyncio
import json
import os
from pathlib import Path
from contextlib import asynccontextmanager
from fastapi import Depends,FastAPI,HTTPException,Request
from zeus_cloud.app import Authorizer
from inference import Runner

root=Path(os.environ.get('ZEUS_COMIC_MODELS_DIR','/models'))
catalog=json.loads(Path(os.environ.get('ZEUS_COMIC_CATALOG','/opt/zeus/comic-models.json')).read_text())
runner=Runner(root,catalog)
auth=Authorizer(os.environ.get('ZEUS_OWNER_ID',''),os.environ.get('ZEUS_OWNER_EMAIL',''))
@asynccontextmanager
async def lifespan(app):
    await asyncio.to_thread(runner.prepare)
    yield
app=FastAPI(lifespan=lifespan,docs_url=None,redoc_url=None)
@app.get('/health')
async def health():return {'service':'zeus-comic-restoration','version':1,'models':{k:v['sha256']for k,v in runner.catalog.items()}}
# One active operation, one waiter. Reject pressure instead of accumulating tensors.
slots=asyncio.Semaphore(1)
waiting=0
@app.post('/v1/comic/infer')
async def infer(request:Request,account=Depends(auth)):
    global waiting
    if waiting>=2:raise HTTPException(429,'Restoration busy; retry later')
    waiting+=1
    try:
        raw=bytearray()
        async for chunk in request.stream():
            raw.extend(chunk)
            if len(raw)>24_000_000:raise HTTPException(413,'Tensor request too large')
        try:
            value=json.loads(raw)
            if value.get('version')!=1:raise ValueError('Unsupported protocol')
            async with slots:
                return await asyncio.to_thread(runner.infer,value['model'],value['inputs'])
        except (ValueError,KeyError,TypeError)as error:raise HTTPException(422,'Invalid model tensors')from error
    finally:waiting-=1
