import asyncio
import os
os.environ.setdefault('ZEUS_COMIC_CATALOG','ZEUSNext/Resources/comic-models.json')
import unittest
from unittest.mock import patch
import httpx
import app as service

class APITests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client=httpx.AsyncClient(transport=httpx.ASGITransport(app=service.app),base_url='https://restoration.test')
    async def asyncTearDown(self):
        service.app.dependency_overrides.clear();await self.client.aclose()
    async def test_requires_auth_before_reading_tensor_request(self):
        response=await self.client.post('/v1/comic/infer',json={'version':1})
        self.assertIn(response.status_code,[401,503])
    async def test_authenticated_request_uses_runner_and_rejects_unknown_protocol(self):
        service.app.dependency_overrides[service.auth]=lambda:'test-owner'
        with patch.object(service.runner,'infer',return_value={'version':1,'output':'encoded'})as infer:
            response=await self.client.post('/v1/comic/infer',json={'version':1,'model':'ctd.onnx','inputs':{'image':'value'}})
            self.assertEqual(response.status_code,200);infer.assert_called_once_with('ctd.onnx',{'image':'value'})
        response=await self.client.post('/v1/comic/infer',json={'version':99})
        self.assertEqual(response.status_code,422)
    async def test_busy_service_does_not_enqueue_more_tensors(self):
        service.app.dependency_overrides[service.auth]=lambda:'test-owner'
        service.waiting=2
        try:
            response=await self.client.post('/v1/comic/infer',json={'version':1})
            self.assertEqual(response.status_code,429)
        finally:service.waiting=0
